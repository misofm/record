// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_record::record_tests;

use miso_record::record;
use sui::dynamic_field as df;

/// Stand-in for an extension's package-private dynamic-field key.
public struct DemoKey() has copy, drop, store;

fun id(addr: address): ID {
    object::id_from_address(addr)
}

#[test]
fun record_holds_fields_and_is_extensible() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let release = id(@0xBEEF);

    let mut r = record::new(release, 7, &mut ctx);
    assert!(record::release_id(&r) == release);
    assert!(record::number(&r) == 7);

    // An extension attaches state through the open uid_mut and reads it back.
    df::add(record::uid_mut(&mut r), DemoKey(), b"pressing");
    assert!(df::exists(record::uid(&r), DemoKey()));
    let _: vector<u8> = df::remove(record::uid_mut(&mut r), DemoKey());

    record::destroy(r);
}
