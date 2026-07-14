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

public struct MinterAuthorizedEvent has copy, drop {
    minter: TypeName,
}

public struct MinterRevokedEvent has copy, drop {
    minter: TypeName,
}

//=== Init ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(Settings {
        id: object::new(ctx),
        minters: vec_set::empty(),
    });
    transfer::transfer(SettingsAdminCap { id: object::new(ctx) }, ctx.sender());
}

//=== Admin Functions ===

/// Authorize the witness type `W` to mint records. Idempotent: authorizing an
/// already-authorized type is a no-op rather than an abort.
public fun authorize<W>(self: &mut Settings, _: &SettingsAdminCap) {
    let minter = type_name::with_defining_ids<W>();
    if (!self.minters.contains(&minter)) {
        self.minters.insert(minter);
        emit(MinterAuthorizedEvent { minter });
    };
}

/// Revoke the witness type `W`. Idempotent: revoking an unauthorized type is a no-op.
public fun revoke<W>(self: &mut Settings, _: &SettingsAdminCap) {
    let minter = type_name::with_defining_ids<W>();
    if (self.minters.contains(&minter)) {
        self.minters.remove(&minter);
        emit(MinterRevokedEvent { minter });
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
    (
        Settings { id: object::new(ctx), minters: vec_set::empty() },
        SettingsAdminCap { id: object::new(ctx) },
    )
}

#[test_only]
public fun destroy_for_testing(self: Settings, cap: SettingsAdminCap) {
    let Settings { id, minters: _ } = self;
    id.delete();
    let SettingsAdminCap { id } = cap;
    id.delete();
}
