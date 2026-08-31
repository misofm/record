// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The Miso Record — an owned copy of a release created by an authorized Miso
/// distribution mechanism.
///
/// `Record` is the distribution format, not a generic substrate for third-party
/// record-like objects. Its creation boundary is therefore governed by
/// `miso_record::settings::Settings`: a caller must consume a witness whose type the Miso
/// admin has authorized. Distribution packages can evolve independently while every
/// object accepted as a `Record` still shares one creation policy.
///
/// A singleton `RecordRegistry` owns the canonical per-release number sequences and
/// UID namespace. Sales packages may be replaced without restarting or redefining
/// those sequences: an authorized witness chooses *how* a purchase is validated,
/// while the Registry alone chooses *which* Record number is created.
///
/// `Record` has `key + store`, making it a freely composable Sui asset. Callers use
/// the framework's `public_*` ownership APIs directly to transfer, wrap, share, or
/// freeze it; this module does not duplicate those operations with convenience
/// wrappers.
module miso_record::record;

use miso_record::settings::Settings;
use std::type_name::{Self, TypeName};
use sui::clock::Clock;
use sui::derived_object;
use sui::event::emit;
use sui::table::{Self, Table};

//=== Structs ===

public struct Record has key, store {
    id: UID,
    /// The release this is a distributed copy of.
    release_id: ID,
    /// The canonical Registry whose UID namespace created this Record.
    registry_id: ID,
    /// This Record's Registry-allocated number within its release.
    number: u64,
    /// When this Record was created, in Unix milliseconds from Sui's Clock.
    created_at_ms: u64,
    /// The currency type used for the purchase that created this Record.
    purchase_currency: TypeName,
    /// The transaction sender who purchased this Record.
    purchased_by: address,
}

/// The singleton namespace and per-release counters for every Record created by this
/// package.
/// Only `mint` mutates it.
public struct RecordRegistry has key {
    id: UID,
    supplies: Table<ID, u64>,
}

/// Key for deriving a Record UID from the Registry. The positional field is
/// module-private, so only this module can claim this key namespace.
public struct RecordKey(ID, u64) has copy, drop, store;

//=== Events ===

public struct RecordCreatedEvent has copy, drop {
    record_id: ID,
    registry_id: ID,
    release_id: ID,
    number: u64,
    created_at_ms: u64,
    purchase_currency: TypeName,
    purchased_by: address,
    witness: TypeName,
}

public struct RecordRegistryCreatedEvent has copy, drop {
    registry_id: ID,
}

public struct RecordDestroyedEvent has copy, drop {
    record_id: ID,
    release_id: ID,
}

//=== Errors ===

#[error(code = 0)]
const ENotAuthorized: vector<u8> = b"The witness type is not authorized to create Records";

//=== Init ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new_registry(ctx));
}

fun new_registry(ctx: &mut TxContext): RecordRegistry {
    let registry = RecordRegistry {
        id: object::new(ctx),
        supplies: table::new(ctx),
    };
    emit(RecordRegistryCreatedEvent { registry_id: object::id(&registry) });
    registry
}

//=== Public Functions ===

/// Create a Record by consuming an authorized distribution witness.
///
/// The Registry advances the release's sequence and derives the Record UID from
/// `(release_id, number)`. `settings` is read immutably; the Registry is the one
/// deliberately mutable shared input that serializes Record creation across every
/// sales implementation.
public fun mint<W: drop, Currency>(
    registry: &mut RecordRegistry,
    settings: &Settings,
    _witness: W,
    release_id: ID,
    clock: &Clock,
    ctx: &TxContext,
): Record {
    assert!(settings.is_authorized<W>(), ENotAuthorized);
    let number = if (table::contains(&registry.supplies, release_id)) {
        let supply = table::borrow_mut(&mut registry.supplies, release_id);
        *supply = *supply + 1;
        *supply
    } else {
        table::add(&mut registry.supplies, release_id, 1);
        1
    };
    let registry_id = object::id(registry);
    let created_at_ms = clock.timestamp_ms();
    let purchase_currency = type_name::with_defining_ids<Currency>();
    let purchased_by = ctx.sender();
    let record = Record {
        id: derived_object::claim(&mut registry.id, RecordKey(release_id, number)),
        release_id,
        registry_id,
        number,
        created_at_ms,
        purchase_currency,
        purchased_by,
    };
    emit(RecordCreatedEvent {
        record_id: object::id(&record),
        registry_id,
        release_id,
        number,
        created_at_ms,
        purchase_currency,
        purchased_by,
        witness: type_name::with_defining_ids<W>(),
    });
    record
}

/// Destroy a Record. Detach any dynamic-field extensions first or they become
/// inaccessible.
public fun destroy(self: Record) {
    let record_id = object::id(&self);
    let Record { id, release_id, .. } = self;
    id.delete();
    emit(RecordDestroyedEvent { record_id, release_id });
}

//=== Extension Access ===

public fun uid(self: &Record): &UID {
    &self.id
}

public fun uid_mut(self: &mut Record): &mut UID {
    &mut self.id
}

//=== View Functions ===

public fun release_id(self: &Record): ID {
    self.release_id
}

public fun registry_id(self: &Record): ID {
    self.registry_id
}

public fun number(self: &Record): u64 {
    self.number
}

public fun created_at_ms(self: &Record): u64 {
    self.created_at_ms
}

public fun purchase_currency(self: &Record): TypeName {
    self.purchase_currency
}

public fun purchased_by(self: &Record): address {
    self.purchased_by
}

public fun supply(self: &RecordRegistry, release_id: ID): u64 {
    if (table::contains(&self.supplies, release_id)) {
        *table::borrow(&self.supplies, release_id)
    } else {
        0
    }
}

public fun derive_address(registry_id: ID, release_id: ID, number: u64): address {
    derived_object::derive_address(registry_id, RecordKey(release_id, number))
}

//=== Test Helpers ===

#[test_only]
public fun record_created_event_fields(
    event: RecordCreatedEvent,
): (ID, ID, ID, u64, u64, TypeName, address, TypeName) {
    let RecordCreatedEvent {
        record_id,
        registry_id,
        release_id,
        number,
        created_at_ms,
        purchase_currency,
        purchased_by,
        witness,
    } = event;
    (
        record_id,
        registry_id,
        release_id,
        number,
        created_at_ms,
        purchase_currency,
        purchased_by,
        witness,
    )
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_registry_for_testing(ctx: &mut TxContext): RecordRegistry {
    new_registry(ctx)
}

#[test_only]
public fun registry_created_event_fields(event: RecordRegistryCreatedEvent): ID {
    let RecordRegistryCreatedEvent { registry_id } = event;
    registry_id
}

#[test_only]
public fun record_destroyed_event_fields(event: RecordDestroyedEvent): (ID, ID) {
    let RecordDestroyedEvent { record_id, release_id } = event;
    (record_id, release_id)
}
