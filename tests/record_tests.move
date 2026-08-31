// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_record::record_tests;

use miso_record::record::{Self, Record};
use miso_record::settings;
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::derived_object;
use sui::dynamic_field as df;
use sui::event;
use sui::test_scenario as ts;

/// Stand-in for a distribution package's module-controlled witness.
public struct DemoWitness() has drop;

/// A witness type that is never authorized.
public struct ImpostorWitness() has drop;

/// Stand-in for an extension's module-private dynamic-field key.
public struct DemoKey() has copy, drop, store;

fun id(addr: address): ID {
    object::id_from_address(addr)
}

fun demo_witness(): DemoWitness {
    DemoWitness()
}

fun impostor_witness(): ImpostorWitness {
    ImpostorWitness()
}

#[test]
fun authorized_witness_mints_a_derived_extensible_record() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let release = id(@0xBEEF);
    let (mut settings, admin_cap) = settings::new_for_testing(&mut ctx);
    settings.authorize<DemoWitness>(&admin_cap);

    let mut parent = object::new(&mut ctx);
    let parent_id = parent.to_inner();
    let mut r = record::mint(&mut parent, &settings, demo_witness(), release, 7);

    assert_eq!(r.release_id(), release);
    assert_eq!(object::id(&r), record::derive_address(parent_id, 7).to_id());
    assert!(object::id(&r) != record::derive_address(release, 7).to_id());

    let mut created_events = event::events_by_type<record::RecordCreatedEvent>();
    assert_eq!(created_events.length(), 1);
    let (record_id, event_parent_id, event_release_id, number, witness) =
        record::record_created_event_fields(created_events.pop_back());
    assert_eq!(record_id, object::id(&r));
    assert_eq!(event_parent_id, parent_id);
    assert_eq!(event_release_id, release);
    assert_eq!(number, 7);
    assert_eq!(witness, type_name::with_defining_ids<DemoWitness>());

    df::add(r.uid_mut(), DemoKey(), b"pressing");
    assert!(df::exists(r.uid(), DemoKey()));
    let _: vector<u8> = df::remove(r.uid_mut(), DemoKey());

    let destroyed_record_id = object::id(&r);
    r.destroy();
    let mut destroyed_events = event::events_by_type<record::RecordDestroyedEvent>();
    assert_eq!(destroyed_events.length(), 1);
    let (record_id, event_release_id) =
        record::record_destroyed_event_fields(destroyed_events.pop_back());
    assert_eq!(record_id, destroyed_record_id);
    assert_eq!(event_release_id, release);

    parent.delete();
    destroy(settings);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = derived_object::EObjectAlreadyExists)]
fun a_number_can_be_minted_at_most_once_per_parent() {
    let mut ctx = tx_context::dummy();
    let (mut settings, admin_cap) = settings::new_for_testing(&mut ctx);
    settings.authorize<DemoWitness>(&admin_cap);
    let mut parent = object::new(&mut ctx);

    let first = record::mint(&mut parent, &settings, demo_witness(), id(@0xBEEF), 1);
    let second = record::mint(&mut parent, &settings, demo_witness(), id(@0xBEEF), 1);

    first.destroy();
    second.destroy();
    parent.delete();
    destroy(settings);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = record::ENotAuthorized)]
fun unauthorized_witness_cannot_mint() {
    let mut ctx = tx_context::dummy();
    let (settings, admin_cap) = settings::new_for_testing(&mut ctx);
    let mut parent = object::new(&mut ctx);

    let record = record::mint(
        &mut parent,
        &settings,
        impostor_witness(),
        id(@0xBEEF),
        1,
    );

    record.destroy();
    parent.delete();
    destroy(settings);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = record::ENotAuthorized)]
fun revoked_witness_cannot_mint() {
    let mut ctx = tx_context::dummy();
    let (mut settings, admin_cap) = settings::new_for_testing(&mut ctx);
    settings.authorize<DemoWitness>(&admin_cap);
    settings.revoke<DemoWitness>(&admin_cap);
    let mut parent = object::new(&mut ctx);

    let record = record::mint(
        &mut parent,
        &settings,
        demo_witness(),
        id(@0xBEEF),
        1,
    );

    record.destroy();
    parent.delete();
    destroy(settings);
    destroy(admin_cap);
}

#[test]
fun the_same_number_under_different_parents_produces_distinct_records() {
    let mut ctx = tx_context::dummy();
    let (mut settings, admin_cap) = settings::new_for_testing(&mut ctx);
    settings.authorize<DemoWitness>(&admin_cap);
    let mut first_parent = object::new(&mut ctx);
    let mut second_parent = object::new(&mut ctx);
    let first_parent_id = first_parent.to_inner();
    let second_parent_id = second_parent.to_inner();

    let first = record::mint(
        &mut first_parent,
        &settings,
        demo_witness(),
        id(@0xCAFE),
        1,
    );
    let second = record::mint(
        &mut second_parent,
        &settings,
        demo_witness(),
        id(@0xCAFE),
        1,
    );

    assert_eq!(object::id(&first), record::derive_address(first_parent_id, 1).to_id());
    assert_eq!(object::id(&second), record::derive_address(second_parent_id, 1).to_id());
    assert!(object::id(&first) != object::id(&second));

    first.destroy();
    second.destroy();
    first_parent.delete();
    second_parent.delete();
    destroy(settings);
    destroy(admin_cap);
}

#[test]
fun different_numbers_under_one_parent_are_distinct_and_precomputable() {
    let mut ctx = tx_context::dummy();
    let (mut settings, admin_cap) = settings::new_for_testing(&mut ctx);
    settings.authorize<DemoWitness>(&admin_cap);
    let mut parent = object::new(&mut ctx);
    let parent_id = parent.to_inner();

    let first = record::mint(&mut parent, &settings, demo_witness(), id(@0xCAFE), 1);
    let second = record::mint(&mut parent, &settings, demo_witness(), id(@0xCAFE), 2);

    assert_eq!(object::id(&first), record::derive_address(parent_id, 1).to_id());
    assert_eq!(object::id(&second), record::derive_address(parent_id, 2).to_id());
    assert!(object::id(&first) != object::id(&second));

    first.destroy();
    second.destroy();
    parent.delete();
    destroy(settings);
    destroy(admin_cap);
}

#[test]
fun settings_tracks_witness_types_and_emits_changes_once() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut settings, admin_cap) = settings::new_for_testing(&mut ctx);
    let settings_id = object::id(&settings);
    let admin_cap_id = object::id(&admin_cap);

    let mut created_events = event::events_by_type<settings::SettingsCreatedEvent>();
    assert_eq!(created_events.length(), 1);
    let (event_settings_id, event_admin_cap_id) =
        settings::settings_created_event_fields(created_events.pop_back());
    assert_eq!(event_settings_id, settings_id);
    assert_eq!(event_admin_cap_id, admin_cap_id);

    settings.authorize<DemoWitness>(&admin_cap);
    settings.authorize<DemoWitness>(&admin_cap);
    assert!(settings.is_authorized<DemoWitness>());
    assert_eq!(settings.witnesses(), vector[type_name::with_defining_ids<DemoWitness>()]);

    let mut authorized_events = event::events_by_type<settings::WitnessAuthorizedEvent>();
    assert_eq!(authorized_events.length(), 1);
    let (event_settings_id, witness) =
        settings::witness_authorized_event_fields(authorized_events.pop_back());
    assert_eq!(event_settings_id, settings_id);
    assert_eq!(witness, type_name::with_defining_ids<DemoWitness>());

    settings.revoke<DemoWitness>(&admin_cap);
    settings.revoke<DemoWitness>(&admin_cap);
    assert!(!settings.is_authorized<DemoWitness>());
    assert!(settings.witnesses().is_empty());

    let mut revoked_events = event::events_by_type<settings::WitnessRevokedEvent>();
    assert_eq!(revoked_events.length(), 1);
    let (event_settings_id, witness) =
        settings::witness_revoked_event_fields(revoked_events.pop_back());
    assert_eq!(event_settings_id, settings_id);
    assert_eq!(witness, type_name::with_defining_ids<DemoWitness>());

    destroy(settings);
    destroy(admin_cap);
}

#[test]
fun init_shares_settings_and_transfers_the_admin_cap() {
    let mut scenario = ts::begin(@0xA);
    settings::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xA);
    let settings = scenario.take_shared<settings::Settings>();
    let admin_cap = scenario.take_from_sender<settings::SettingsAdminCap>();
    assert!(settings.witnesses().is_empty());

    ts::return_shared(settings);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun record_transfers_by_address() {
    let mut scenario = ts::begin(@0xA);
    let (mut settings, admin_cap) = settings::new_for_testing(scenario.ctx());
    settings.authorize<DemoWitness>(&admin_cap);
    let mut parent = object::new(scenario.ctx());
    let record = record::mint(
        &mut parent,
        &settings,
        demo_witness(),
        id(@0xBEEF),
        1,
    );
    let record_id = object::id(&record);

    parent.delete();
    destroy(settings);
    destroy(admin_cap);
    record.transfer(@0xB);

    scenario.next_tx(@0xB);
    let received = scenario.take_from_sender<Record>();
    assert_eq!(object::id(&received), record_id);
    received.destroy();

    scenario.end();
}
