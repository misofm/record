// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Creation policy for Miso Records.
///
/// `Settings` stores the one witness type currently authorized to create Records. A
/// sales package defines a witness whose construction it controls, and the Miso admin
/// may atomically replace that type when the complete sales implementation changes.
/// Multiple purchase paths that coexist belong behind that sales package's one
/// witness boundary.
module miso_record::settings;

use std::type_name::{Self, TypeName};
use sui::event::emit;

//=== Structs ===

/// The single witness type currently authorized to create Records, if any.
public struct Settings has key {
    id: UID,
    witness: Option<TypeName>,
}

/// Authority to replace or clear the active witness type.
public struct SettingsAdminCap has key, store {
    id: UID,
}

//=== Events ===

public struct SettingsCreatedEvent has copy, drop {
    settings_id: ID,
    admin_cap_id: ID,
}

public struct WitnessSetEvent has copy, drop {
    settings_id: ID,
    previous_witness: Option<TypeName>,
    witness: TypeName,
}

public struct WitnessClearedEvent has copy, drop {
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
        witness: option::none(),
    };
    let admin_cap = SettingsAdminCap { id: object::new(ctx) };
    emit(SettingsCreatedEvent {
        settings_id: object::id(&settings),
        admin_cap_id: object::id(&admin_cap),
    });
    (settings, admin_cap)
}

//=== Admin Functions ===

/// Make `W` the only witness type authorized to create Records. This atomically
/// replaces the previous witness and is idempotent when `W` is already active.
///
/// `W` should be a module-controlled, non-copyable witness whose values are only
/// created by the sales paths that Miso intends to authorize.
public fun set_witness<W: drop>(self: &mut Settings, _: &SettingsAdminCap) {
    let witness = type_name::with_defining_ids<W>();
    let previous_witness = self.witness;
    let next_witness = option::some(witness);
    if (previous_witness != next_witness) {
        self.witness = next_witness;
        emit(WitnessSetEvent {
            settings_id: object::id(self),
            previous_witness,
            witness,
        });
    };
}

/// Remove the active witness, disabling all Record creation. This is idempotent.
public fun clear_witness(self: &mut Settings, _: &SettingsAdminCap) {
    if (self.witness.is_some()) {
        let witness = self.witness.extract();
        emit(WitnessClearedEvent {
            settings_id: object::id(self),
            witness,
        });
    };
}

//=== View Functions ===

/// Whether witness type `W` is authorized to create Records.
public fun is_authorized<W: drop>(self: &Settings): bool {
    self.witness == option::some(type_name::with_defining_ids<W>())
}

/// The currently authorized witness type, if Record creation is enabled.
public fun witness(self: &Settings): Option<TypeName> {
    self.witness
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
public fun witness_set_event_fields(
    event: WitnessSetEvent,
): (ID, Option<TypeName>, TypeName) {
    let WitnessSetEvent { settings_id, previous_witness, witness } = event;
    (settings_id, previous_witness, witness)
}

#[test_only]
public fun witness_cleared_event_fields(event: WitnessClearedEvent): (ID, TypeName) {
    let WitnessClearedEvent { settings_id, witness } = event;
    (settings_id, witness)
}
