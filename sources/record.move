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
/// Every Record is derived from its distribution parent and a claim number. This
/// makes its address predictable and prevents a claim number from being reused for
/// the same parent. The number remains distribution context rather than Record data.
///
/// `Record` is key-only. This module exposes address transfer, but deliberately
/// exposes no sharing or freezing path and cannot be bypassed through the framework's
/// `public_*` transfer APIs.
module miso_record::record;

use miso_record::settings::Settings;
use std::type_name::{Self, TypeName};
use sui::derived_object;
use sui::event::emit;

//=== Structs ===

public struct Record has key {
    id: UID,
    /// The release this is a distributed copy of.
    release_id: ID,
}

/// Key for deriving a Record UID from its distribution parent. The positional field
/// is module-private, so only this module can claim this key namespace.
public struct RecordKey(u64) has copy, drop, store;

//=== Events ===

public struct RecordCreatedEvent has copy, drop {
    record_id: ID,
    parent_id: ID,
    release_id: ID,
    number: u64,
    witness: TypeName,
}

public struct RecordDestroyedEvent has copy, drop {
    record_id: ID,
    release_id: ID,
}

//=== Errors ===

#[error(code = 0)]
const ENotAuthorized: vector<u8> = b"The witness type is not authorized to create Records";

//=== Public Functions ===

/// Create a Record by consuming an authorized distribution witness.
///
/// The Record UID is derived from `parent` and `number`; a pair can be claimed only
/// once. `settings` is read immutably so unrelated distributions do not contend on
/// the shared Settings object.
public fun mint<W: drop>(
    parent: &mut UID,
    settings: &Settings,
    _witness: W,
    release_id: ID,
    number: u64,
): Record {
    assert!(settings.is_authorized<W>(), ENotAuthorized);
    let parent_id = parent.to_inner();
    let record = Record {
        id: derived_object::claim(parent, RecordKey(number)),
        release_id,
    };
    emit(RecordCreatedEvent {
        record_id: object::id(&record),
        parent_id,
        release_id,
        number,
        witness: type_name::with_defining_ids<W>(),
    });
    record
}

/// Transfer a Record to `recipient`.
public fun transfer(record: Record, recipient: address) {
    transfer::transfer(record, recipient)
}

/// Destroy a Record. Detach any dynamic-field extensions first or they become
/// inaccessible.
public fun destroy(self: Record) {
    let record_id = object::id(&self);
    let Record { id, release_id } = self;
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

public fun derive_address(parent: ID, number: u64): address {
    derived_object::derive_address(parent, RecordKey(number))
}

//=== Test Helpers ===

#[test_only]
public fun record_created_event_fields(
    event: RecordCreatedEvent,
): (ID, ID, ID, u64, TypeName) {
    let RecordCreatedEvent { record_id, parent_id, release_id, number, witness } = event;
    (record_id, parent_id, release_id, number, witness)
}

#[test_only]
public fun record_destroyed_event_fields(event: RecordDestroyedEvent): (ID, ID) {
    let RecordDestroyedEvent { record_id, release_id } = event;
    (record_id, release_id)
}
