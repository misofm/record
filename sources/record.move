// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// An owned purchase minted from one edition of a Miso release.
///
/// `Pressing` owns issuance. This module owns only the Record asset and its
/// deterministic identity within that Pressing. Distribution mechanics such as
/// pricing and payment validation live in authorized distributor packages.
module miso_record::record;

use std::type_name::{Self, TypeName};
use sui::{clock::Clock, derived_object, event::emit};

// === Structs ===

/// An owned copy from one edition of a Miso release, including its purchase provenance.
public struct Record has key, store {
    id: UID,
    /// The release this Record is a copy of.
    release_id: ID,
    /// The edition-scoped Pressing that minted this Record.
    pressing_id: ID,
    /// The edition represented by `pressing_id`.
    edition: u16,
    /// This Record's number within its edition.
    number: u32,
    /// The defining type of the currency used for this purchase.
    purchase_currency: TypeName,
    /// The actual amount paid, including any accepted overpayment.
    purchase_price: u64,
    /// The transaction sender who purchased this Record.
    purchased_by: address,
    /// When this Record was purchased, in Unix milliseconds from Sui's Clock.
    purchased_timestamp_ms: u64,
}

/// Key for deriving a Record UID from its Pressing.
public struct RecordKey(u32) has copy, drop, store;

// === Events ===

/// Emitted when a Pressing creates a Record.
public struct RecordCreatedEvent has copy, drop {
    /// The newly created Record.
    record_id: ID,
    /// The release represented by the Record.
    release_id: ID,
    /// The Pressing that issued the Record.
    pressing_id: ID,
    /// The edition represented by the Pressing.
    edition: u16,
    /// The Record's number within the edition.
    number: u32,
}

/// Emitted when an owner permanently destroys a Record.
public struct RecordDestroyedEvent has copy, drop {
    /// The destroyed Record.
    record_id: ID,
    /// The Pressing that issued the Record.
    pressing_id: ID,
}

// === Package Functions ===

/// Mint the next Record in a Pressing's sequence.
///
/// Only another module in `miso_record` can call this constructor. `Pressing`
/// allocates `number` and checks distributor authorization and supply before
/// reaching this function.
public(package) fun new<Currency>(
    pressing_uid: &mut UID,
    release_id: ID,
    edition: u16,
    number: u32,
    purchase_price: u64,
    clock: &Clock,
    ctx: &TxContext,
): Record {
    let pressing_id = pressing_uid.to_inner();
    let purchase_currency = type_name::with_defining_ids<Currency>();
    let purchased_by = ctx.sender();
    let purchased_timestamp_ms = clock.timestamp_ms();
    let record = Record {
        id: derived_object::claim(pressing_uid, RecordKey(number)),
        release_id,
        pressing_id,
        edition,
        number,
        purchase_currency,
        purchase_price,
        purchased_by,
        purchased_timestamp_ms,
    };

    emit(RecordCreatedEvent {
        record_id: object::id(&record),
        release_id,
        pressing_id,
        edition,
        number,
    });

    record
}

// === Public Functions ===

/// Destroy a Record. Detach any dynamic-field extensions first or they become
/// inaccessible.
public fun destroy(self: Record) {
    let record_id = object::id(&self);
    let Record { id, pressing_id, .. } = self;
    id.delete();
    emit(RecordDestroyedEvent { record_id, pressing_id });
}

// === Extension Access ===

/// Borrow the Record UID for read-only extensions.
public fun uid(self: &Record): &UID {
    &self.id
}

/// Mutably borrow the Record UID for owner-authorized extensions.
public fun uid_mut(self: &mut Record): &mut UID {
    &mut self.id
}

// === View Functions ===

/// Return the release represented by this Record.
public fun release_id(self: &Record): ID {
    self.release_id
}

/// Return the Pressing that issued this Record.
public fun pressing_id(self: &Record): ID {
    self.pressing_id
}

/// Return this Record's edition number.
public fun edition(self: &Record): u16 {
    self.edition
}

/// Return this Record's number within its edition.
public fun number(self: &Record): u32 {
    self.number
}

/// Return the defining type of the purchase currency.
public fun purchase_currency(self: &Record): TypeName {
    self.purchase_currency
}

/// Return the amount paid for this Record.
public fun purchase_price(self: &Record): u64 {
    self.purchase_price
}

/// Return the transaction sender who purchased this Record.
public fun purchased_by(self: &Record): address {
    self.purchased_by
}

/// Return the purchase time in Unix milliseconds from Sui's Clock.
public fun purchased_timestamp_ms(self: &Record): u64 {
    self.purchased_timestamp_ms
}

/// Derive the Record address for `number` in `pressing_id`'s edition.
public fun derive_address(pressing_id: ID, number: u32): address {
    derived_object::derive_address(pressing_id, RecordKey(number))
}

// === Test Functions ===

#[test_only]
public fun created_event_fields(
    event: RecordCreatedEvent,
): (ID, ID, ID, u16, u32) {
    let RecordCreatedEvent {
        record_id,
        release_id,
        pressing_id,
        edition,
        number,
    } = event;
    (
        record_id,
        release_id,
        pressing_id,
        edition,
        number,
    )
}

#[test_only]
public fun destroyed_event_fields(event: RecordDestroyedEvent): (ID, ID) {
    let RecordDestroyedEvent { record_id, pressing_id } = event;
    (record_id, pressing_id)
}
