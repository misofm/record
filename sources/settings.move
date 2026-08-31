// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Creation policy for Miso Records.
///
/// `Settings` is a shared allowlist of witness types. A distribution module defines
/// a witness whose construction it controls, the Miso admin authorizes that type,
/// and the module consumes a witness when it calls `record::mint`. This lets Miso
/// add distribution mechanisms without changing the `Record` type or redeploying
/// this package.
module miso_record::settings;

use std::type_name::{Self, TypeName};
use sui::event::emit;
use sui::vec_set::{Self, VecSet};

//=== Structs ===

/// Shared allowlist of witness types authorized to create Records.
public struct Settings has key {
    id: UID,
    witnesses: VecSet<TypeName>,
}

/// Authority to change the witness allowlist.
public struct SettingsAdminCap has key, store {
    id: UID,
}

//=== Events ===

public struct SettingsCreatedEvent has copy, drop {
    settings_id: ID,
    admin_cap_id: ID,
}

public struct WitnessAuthorizedEvent has copy, drop {
    settings_id: ID,
    witness: TypeName,
}

public struct WitnessRevokedEvent has copy, drop {
    settings_id: ID,
    witness: TypeName,
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
        witnesses: vec_set::empty(),
    };
    let admin_cap = SettingsAdminCap { id: object::new(ctx) };
    emit(SettingsCreatedEvent {
        settings_id: object::id(&settings),
        admin_cap_id: object::id(&admin_cap),
    });
    (settings, admin_cap)
}

//=== Admin Functions ===

/// Authorize witness type `W` to create Records. This is idempotent.
///
/// `W` should be a module-controlled, non-copyable witness whose values are only
/// created by the distribution path that Miso intends to authorize.
public fun authorize<W: drop>(self: &mut Settings, _: &SettingsAdminCap) {
    let witness = type_name::with_defining_ids<W>();
    if (!self.witnesses.contains(&witness)) {
        self.witnesses.insert(witness);
        emit(WitnessAuthorizedEvent {
            settings_id: object::id(self),
            witness,
        });
    };
}

/// Revoke witness type `W`. This is idempotent.
public fun revoke<W: drop>(self: &mut Settings, _: &SettingsAdminCap) {
    let witness = type_name::with_defining_ids<W>();
    if (self.witnesses.contains(&witness)) {
        self.witnesses.remove(&witness);
        emit(WitnessRevokedEvent {
            settings_id: object::id(self),
            witness,
        });
    };
}

//=== View Functions ===

/// Whether witness type `W` is authorized to create Records.
public fun is_authorized<W: drop>(self: &Settings): bool {
    self.witnesses.contains(&type_name::with_defining_ids<W>())
}

/// All currently authorized witness types.
public fun witnesses(self: &Settings): vector<TypeName> {
    *self.witnesses.keys()
}

//=== Test Helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): (Settings, SettingsAdminCap) {
    new(ctx)
}

#[test_only]
public fun settings_created_event_fields(event: SettingsCreatedEvent): (ID, ID) {
    let SettingsCreatedEvent { settings_id, admin_cap_id } = event;
    (settings_id, admin_cap_id)
}

#[test_only]
public fun witness_authorized_event_fields(event: WitnessAuthorizedEvent): (ID, TypeName) {
    let WitnessAuthorizedEvent { settings_id, witness } = event;
    (settings_id, witness)
}

#[test_only]
public fun witness_revoked_event_fields(event: WitnessRevokedEvent): (ID, TypeName) {
    let WitnessRevokedEvent { settings_id, witness } = event;
    (settings_id, witness)
}
