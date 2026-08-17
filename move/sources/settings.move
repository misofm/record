// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Minting authority for records.
///
/// `Record` is deliberately package-free: it has no dependency on any sale or
/// pressing package. But once minting lives *outside* this package, something has
/// to say *which* external packages may mint a record — otherwise any module could
/// forge one. That is this object's whole job.
///
/// `Settings` is a shared allowlist of *minter witness types*. A pressing (or any
/// other sale mechanic) defines its own witness type, mints a value of it only on
/// its paid path, and hands it to `record::mint`. `record::mint` asks `Settings`
/// whether that witness *type* is authorized — so authority is "this type may mint",
/// checked at runtime by `TypeName`, never a compile-time dependency on the sale
/// package.
///
/// The payoff: a brand-new sale package with different mechanics (an auction, a
/// giveaway) plugs in with zero redeploy of this package — an admin just authorizes
/// its witness type.
module miso_record::settings;

use std::type_name::{Self, TypeName};
use sui::event::emit;
use sui::vec_set::{Self, VecSet};

//=== Structs ===

/// Shared allowlist of minter witness types permitted to mint a `Record`.
public struct Settings has key {
    id: UID,
    /// The `TypeName` of every authorized minter witness.
    minters: VecSet<TypeName>,
}

/// Authority to change the minter allowlist. Held by whoever published the package.
public struct SettingsAdminCap has key, store {
    id: UID,
}

//=== Events ===

public struct SettingsCreatedEvent has copy, drop {
    settings_id: ID,
    admin_cap_id: ID,
    admin: address,
}

public struct MinterAuthorizedEvent has copy, drop {
    settings_id: ID,
    admin_cap_id: ID,
    minter: TypeName,
    authorized_by: address,
}

public struct MinterRevokedEvent has copy, drop {
    settings_id: ID,
    admin_cap_id: ID,
    minter: TypeName,
    revoked_by: address,
}

//=== Init ===

fun init(ctx: &mut TxContext) {
    let (settings, admin_cap) = new(ctx);
    transfer::share_object(settings);
    transfer::transfer(admin_cap, ctx.sender());
}

fun new(ctx: &mut TxContext): (Settings, SettingsAdminCap) {
    let settings = Settings {
        id: object::new(ctx),
        minters: vec_set::empty(),
    };
    let admin_cap = SettingsAdminCap { id: object::new(ctx) };
    emit(SettingsCreatedEvent {
        settings_id: object::id(&settings),
        admin_cap_id: object::id(&admin_cap),
        admin: ctx.sender(),
    });
    (settings, admin_cap)
}

//=== Admin Functions ===

/// Authorize the witness type `W` to mint records. Idempotent: authorizing an
/// already-authorized type is a no-op rather than an abort.
public fun authorize<W>(
    self: &mut Settings,
    admin_cap: &SettingsAdminCap,
    ctx: &TxContext,
) {
    let minter = type_name::with_defining_ids<W>();
    if (!self.minters.contains(&minter)) {
        self.minters.insert(minter);
        emit(MinterAuthorizedEvent {
            settings_id: object::id(self),
            admin_cap_id: object::id(admin_cap),
            minter,
            authorized_by: ctx.sender(),
        });
    };
}

/// Revoke the witness type `W`. Idempotent: revoking an unauthorized type is a no-op.
public fun revoke<W>(
    self: &mut Settings,
    admin_cap: &SettingsAdminCap,
    ctx: &TxContext,
) {
    let minter = type_name::with_defining_ids<W>();
    if (self.minters.contains(&minter)) {
        self.minters.remove(&minter);
        emit(MinterRevokedEvent {
            settings_id: object::id(self),
            admin_cap_id: object::id(admin_cap),
            minter,
            revoked_by: ctx.sender(),
        });
    };
}

//=== View Functions ===

/// Whether the witness type `W` is authorized to mint.
public fun is_authorized<W>(self: &Settings): bool {
    self.minters.contains(&type_name::with_defining_ids<W>())
}

/// The `TypeName`s of all authorized minter witnesses.
public fun minters(self: &Settings): vector<TypeName> {
    *self.minters.keys()
}

//=== Test Helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

/// Build an (unshared) `Settings` and its admin cap directly, for tests that don't
/// want to run `init` / take from a scenario.
#[test_only]
public fun new_for_testing(ctx: &mut TxContext): (Settings, SettingsAdminCap) {
    new(ctx)
}

#[test_only]
public fun destroy_for_testing(self: Settings, cap: SettingsAdminCap) {
    let Settings { id, minters: _ } = self;
    id.delete();
    let SettingsAdminCap { id } = cap;
    id.delete();
}

#[test_only]
public fun settings_created_event_fields(event: SettingsCreatedEvent): (ID, ID, address) {
    let SettingsCreatedEvent { settings_id, admin_cap_id, admin } = event;
    (settings_id, admin_cap_id, admin)
}

#[test_only]
public fun minter_authorized_event_fields(
    event: MinterAuthorizedEvent,
): (ID, ID, TypeName, address) {
    let MinterAuthorizedEvent { settings_id, admin_cap_id, minter, authorized_by } = event;
    (settings_id, admin_cap_id, minter, authorized_by)
}

#[test_only]
public fun minter_revoked_event_fields(
    event: MinterRevokedEvent,
): (ID, ID, TypeName, address) {
    let MinterRevokedEvent { settings_id, admin_cap_id, minter, revoked_by } = event;
    (settings_id, admin_cap_id, minter, revoked_by)
}
