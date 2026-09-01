// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// An owned copy minted from one edition of a Miso release.
///
/// `Pressing` owns issuance. This module owns only the Record asset and its
/// deterministic identity within that Pressing. Distribution mechanics such as
/// prices, payments, redemptions, and recipients live in authorized distributor
/// packages.
module miso_record::record;

use std::type_name::{Self, TypeName};
use sui::clock::Clock;
use sui::derived_object;
use sui::event::emit;

//=== Structs ===

public struct Record has key, store {
    id: UID,
    /// The release this Record is a copy of.
    release_id: ID,
    /// The edition-scoped Pressing that minted this Record.
    pressing_id: ID,
    /// The edition represented by `pressing_id`.
    edition: u64,
    /// This Record's 1-based number within its edition.
    number: u64,
    /// When this Record was minted, in Unix milliseconds from Sui's Clock.
    created_at_ms: u64,
}

/// Key for deriving a Record UID from its Pressing.
public struct RecordKey(u64) has copy, drop, store;

//=== Events ===

public struct RecordCreated has copy, drop {
    record_id: ID,
    release_id: ID,
    pressing_id: ID,
    edition: u64,
    number: u64,
    created_at_ms: u64,
    distributor: TypeName,
}

public struct RecordDestroyed has copy, drop {
    record_id: ID,
    pressing_id: ID,
}

//=== Package Functions ===

/// Mint the next Record in a Pressing's sequence.
///
/// Only another module in `miso_record` can call this constructor. `Pressing`
/// allocates `number` and checks distributor authorization and supply before
/// reaching this function.
public(package) fun new<Distributor: drop>(
    pressing_uid: &mut UID,
    release_id: ID,
    edition: u64,
    number: u64,
    clock: &Clock,
): Record {
    let pressing_id = pressing_uid.to_inner();
    let created_at_ms = clock.timestamp_ms();
    let record = Record {
        id: derived_object::claim(pressing_uid, RecordKey(number)),
        release_id,
        pressing_id,
        edition,
        number,
        created_at_ms,
    };

    emit(RecordCreated {
        record_id: object::id(&record),
        release_id,
        pressing_id,
        edition,
        number,
        created_at_ms,
        distributor: type_name::with_defining_ids<Distributor>(),
    });

    record
}

//=== Public Functions ===

/// Destroy a Record. Detach any dynamic-field extensions first or they become
/// inaccessible.
public fun destroy(self: Record) {
    let record_id = object::id(&self);
    let Record { id, pressing_id, .. } = self;
    id.delete();
    emit(RecordDestroyed { record_id, pressing_id });
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

public fun pressing_id(self: &Record): ID {
    self.pressing_id
}

public fun edition(self: &Record): u64 {
    self.edition
}

public fun number(self: &Record): u64 {
    self.number
}

public fun created_at_ms(self: &Record): u64 {
    self.created_at_ms
}

/// Derive the Record ID for a 1-based number in `pressing_id`'s edition.
public fun derive_id(pressing_id: ID, number: u64): ID {
    derived_object::derive_address(pressing_id, RecordKey(number)).to_id()
}

//=== Test Helpers ===

#[test_only]
public fun created_event_fields(
    event: RecordCreated,
): (ID, ID, ID, u64, u64, u64, TypeName) {
    let RecordCreated {
        record_id,
        release_id,
        pressing_id,
        edition,
        number,
        created_at_ms,
        distributor,
    } = event;
    (
        record_id,
        release_id,
        pressing_id,
        edition,
        number,
        created_at_ms,
        distributor,
    )
}

#[test_only]
public fun destroyed_event_fields(event: RecordDestroyed): (ID, ID) {
    let RecordDestroyed { record_id, pressing_id } = event;
    (record_id, pressing_id)
}
