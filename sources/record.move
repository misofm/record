// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

module record::record;

// === Imports ===

use std::type_name::{Self, TypeName};
use sui::{clock::Clock, derived_object, event::emit};

// === Structs ===

public struct Record has key, store {
    id: UID,
    release_id: ID,
    pressing_id: ID,
    edition: u16,
    number: u32,
    purchase_currency: TypeName,
    purchase_price: u64,
    purchased_at_ms: u64,
}

public struct RecordKey(u32) has copy, drop, store;

// === Events ===

public struct RecordDestroyedEvent has copy, drop {
    record_id: ID,
}

// === Public Functions ===

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

public fun purchased_at_ms(self: &Record): u64 {
    self.purchased_at_ms
}

public fun derive_address(pressing_id: ID, number: u32): address {
    derived_object::derive_address(pressing_id, RecordKey(number))
}

public fun uid(self: &Record): &UID {
    &self.id
}

public fun uid_mut(self: &mut Record): &mut UID {
    &mut self.id
}

// === Private Functions ===

public(package) fun new<Currency>(
    pressing_uid: &mut UID,
    release_id: ID,
    edition: u16,
    number: u32,
    purchase_price: u64,
    clock: &Clock,
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
        purchased_at_ms: clock.timestamp_ms(),
    }
}

// === Test Functions ===

#[test_only]
public fun destroyed_event_record_id(event: &RecordDestroyedEvent): ID {
    event.record_id
}
