// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// An owned copy from one edition of a Miso release, with its purchase provenance.
///
/// `pressing` allocates each Record's number and is the only caller of `new`.
/// Record IDs derive from `(pressing_id, RecordKey(number))`. Distributor
/// packages own pricing and payment validation.
module record::record;

// === Imports ===

use std::type_name::{Self, TypeName};
use sui::{derived_object, event::emit};

// === Structs ===

/// One numbered Record of a Pressing.
public struct Record has key, store {
    id: UID,
    release_id: ID,
    pressing_id: ID,
    edition: u16,
    /// Edition-local number, starting at 1.
    number: u32,
    /// Defining type of the purchase currency.
    purchase_currency: TypeName,
    /// Amount actually paid, including any accepted overpayment.
    purchase_price: u64,
}

public struct RecordKey(u32) has copy, drop, store;

// === Events ===

/// Purchase provenance is in the matching `RecordPurchasedEvent`.
public struct RecordDestroyedEvent has copy, drop {
    record_id: ID,
}

// === Public Functions ===

/// Destroys a Record. Detach dynamic-field extensions first or they become
/// inaccessible.
public fun destroy(self: Record) {
    let record_id = object::id(&self);
    let Record { id, .. } = self;
    id.delete();
    emit(RecordDestroyedEvent { record_id });
}

// === View Functions ===

public fun release_id(self: &Record): ID {
    self.release_id
}

public fun pressing_id(self: &Record): ID {
    self.pressing_id
}

public fun edition(self: &Record): u16 {
    self.edition
}

public fun number(self: &Record): u32 {
    self.number
}

public fun purchase_currency(self: &Record): TypeName {
    self.purchase_currency
}

public fun purchase_price(self: &Record): u64 {
    self.purchase_price
}

/// The address of Record `number` in `pressing_id`'s edition.
public fun derive_address(pressing_id: ID, number: u32): address {
    derived_object::derive_address(pressing_id, RecordKey(number))
}

public fun uid(self: &Record): &UID {
    &self.id
}

/// Open to any holder: sharing a Record makes extension mutation public.
public fun uid_mut(self: &mut Record): &mut UID {
    &mut self.id
}

// === Package Functions ===

/// Mints Record `number`. Only `pressing::mint` calls this, after checking
/// distributor authorization and supply.
public(package) fun new<Currency>(
    pressing_uid: &mut UID,
    release_id: ID,
    edition: u16,
    number: u32,
    purchase_price: u64,
): Record {
    let pressing_id = pressing_uid.to_inner();
    Record {
        id: derived_object::claim(pressing_uid, RecordKey(number)),
        release_id,
        pressing_id,
        edition,
        number,
        purchase_currency: type_name::with_defining_ids<Currency>(),
        purchase_price,
    }
}

// === Test Functions ===

#[test_only]
public fun destroyed_event_record_id(event: &RecordDestroyedEvent): ID {
    event.record_id
}
