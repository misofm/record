// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_record::record_tests;

use miso_record::record::{Self, Record};
use std::unit_test::assert_eq;
use sui::derived_object;
use sui::dynamic_field as df;
use sui::event;
use sui::test_scenario as ts;

/// Stand-in for a sale package's package-private certificate.
public struct DemoCertificate(u64) has drop, store;

/// A separate issuer's certificate type.
public struct Impostor has drop, store {}

/// Stand-in for an extension's package-private dynamic-field key.
public struct DemoKey() has copy, drop, store;

fun id(addr: address): ID {
    object::id_from_address(addr)
}

#[test]
fun new_embeds_the_certificate_and_derives_off_the_parent() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let release = id(@0xBEEF);
    let mut parent = object::new(&mut ctx);
    let parent_id = parent.to_inner();
    let mut r = record::new(&mut parent, DemoCertificate(42), release, 7);
    assert_eq!(record::release_id(&r), release);
    assert_eq!(record::certificate(&r).0, 42);
    assert_eq!(record::uid(&r).to_inner(), object::id(&r));

    // Every record derives off its minting parent: the address is pure math over the
    // parent and the claim slot, so provenance is verifiable by recomputing it. The
    // record does not store the slot — the issuer's serial field names it.
    assert_eq!(object::id(&r), record::derive_address(parent.to_inner(), 7).to_id());
    assert!(object::id(&r) != record::derive_address(release, 7).to_id());

    let mut created_events = event::events_by_type<record::RecordCreatedEvent<DemoCertificate>>();
    assert_eq!(created_events.length(), 1);
    let (record_id, event_parent_id, event_release_id, number) =
        record::record_created_event_fields(created_events.pop_back());
    assert_eq!(record_id, object::id(&r));
    assert_eq!(event_parent_id, parent_id);
    assert_eq!(event_release_id, release);
    assert_eq!(number, 7);
    let _: &DemoCertificate = record::certificate(&r);

    // An extension attaches state through the open uid_mut and reads it back.
    df::add(record::uid_mut(&mut r), DemoKey(), b"pressing");
    assert!(df::exists(record::uid(&r), DemoKey()));
    let _: vector<u8> = df::remove(record::uid_mut(&mut r), DemoKey());

    let destroyed_record_id = object::id(&r);
    record::destroy(r);
    let mut destroyed_events =
        event::events_by_type<record::RecordDestroyedEvent<DemoCertificate>>();
    assert_eq!(destroyed_events.length(), 1);
    let (record_id, event_release_id) =
        record::record_destroyed_event_fields(destroyed_events.pop_back());
    assert_eq!(record_id, destroyed_record_id);
    assert_eq!(event_release_id, release);
    parent.delete();
}

#[test, expected_failure(abort_code = derived_object::EObjectAlreadyExists)]
fun a_number_can_be_minted_at_most_once_per_parent_across_certificate_types() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let mut parent = object::new(&mut ctx);
    let r1 = record::new(&mut parent, DemoCertificate(1), id(@0xBEEF), 1);
    let r2 = record::new(&mut parent, Impostor {}, id(@0xBEEF), 1);

    // Statically required resource cleanup; unreachable after the expected abort.
    record::destroy(r1);
    record::destroy(r2);
    parent.delete();
}

#[test]
fun certificate_types_have_isolated_event_streams() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let mut parent = object::new(&mut ctx);
    let demo = record::new(&mut parent, DemoCertificate(10), id(@0xA11CE), 1);
    let other = record::new(&mut parent, Impostor {}, id(@0xB0B), 2);

    let demo_created = event::events_by_type<record::RecordCreatedEvent<DemoCertificate>>();
    let other_created = event::events_by_type<record::RecordCreatedEvent<Impostor>>();
    assert_eq!(demo_created.length(), 1);
    assert_eq!(other_created.length(), 1);

    record::destroy(demo);
    record::destroy(other);

    let demo_destroyed = event::events_by_type<record::RecordDestroyedEvent<DemoCertificate>>();
    let other_destroyed = event::events_by_type<record::RecordDestroyedEvent<Impostor>>();
    assert_eq!(demo_destroyed.length(), 1);
    assert_eq!(other_destroyed.length(), 1);
    parent.delete();
}

#[test]
fun slots_are_unique_per_parent_not_globally() {
    let mut ctx = tx_context::dummy();
    let mut first_parent = object::new(&mut ctx);
    let mut second_parent = object::new(&mut ctx);
    let first_parent_id = first_parent.to_inner();
    let second_parent_id = second_parent.to_inner();
    let expected_first = record::derive_address(first_parent_id, 1).to_id();
    let expected_second = record::derive_address(second_parent_id, 1).to_id();

    let first = record::new(&mut first_parent, DemoCertificate(1), id(@0xCAFE), 1);
    let second = record::new(&mut second_parent, DemoCertificate(1), id(@0xCAFE), 1);

    assert_eq!(object::id(&first), expected_first);
    assert_eq!(object::id(&second), expected_second);
    assert!(object::id(&first) != object::id(&second));

    record::destroy(first);
    record::destroy(second);
    first_parent.delete();
    second_parent.delete();
}

#[test]
fun different_slots_on_one_parent_are_distinct_and_precomputable() {
    let mut ctx = tx_context::dummy();
    let mut parent = object::new(&mut ctx);
    let parent_id = parent.to_inner();
    let expected_first = record::derive_address(parent_id, 1).to_id();
    let expected_second = record::derive_address(parent_id, 2).to_id();

    let first = record::new(&mut parent, DemoCertificate(1), id(@0xCAFE), 1);
    let second = record::new(&mut parent, DemoCertificate(2), id(@0xCAFE), 2);

    assert_eq!(object::id(&first), expected_first);
    assert_eq!(object::id(&second), expected_second);
    assert!(expected_first != expected_second);

    record::destroy(first);
    record::destroy(second);
    parent.delete();
}

#[test]
fun record_transfers_by_address_with_its_certificate() {
    let mut scenario = ts::begin(@0xA);
    let mut parent = object::new(scenario.ctx());
    let record = record::new(
        &mut parent,
        DemoCertificate(77),
        id(@0xBEEF),
        1,
    );
    let record_id = object::id(&record);
    parent.delete();
    record::transfer(record, @0xB);

    scenario.next_tx(@0xB);
    let received = scenario.take_from_sender<Record<DemoCertificate>>();
    assert_eq!(object::id(&received), record_id);
    assert_eq!(received.certificate().0, 77);
    received.destroy();

    let destroyed = event::events_by_type<record::RecordDestroyedEvent<DemoCertificate>>();
    assert_eq!(destroyed.length(), 1);
    scenario.end();
}
