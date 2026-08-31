// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_record::record_tests;

use miso_record::record::{Self, Record, RecordRegistry};
use miso_record::settings;
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::clock;
use sui::dynamic_field as df;
use sui::event;
use sui::sui::SUI;
use sui::test_scenario as ts;

/// Stand-in for the active sales package's module-controlled witness.
public struct DemoWitness() has drop;

/// Stand-in for a complete replacement sales package.
public struct ReplacementWitness() has drop;

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

fun replacement_witness(): ReplacementWitness {
    ReplacementWitness()
}

fun impostor_witness(): ImpostorWitness {
    ImpostorWitness()
}

fun mint_record<W: drop, Currency>(
    registry: &mut RecordRegistry,
    settings: &settings::Settings,
    witness: W,
    release_id: ID,
    created_at_ms: u64,
    ctx: &mut TxContext,
): Record {
    let mut clk = clock::create_for_testing(ctx);
    clk.set_for_testing(created_at_ms);
    let record = record::mint<W, Currency>(
        registry,
        settings,
        witness,
        release_id,
        &clk,
        ctx,
    );
    clk.destroy_for_testing();
    record
}

#[test]
fun authorized_witness_mints_a_self_describing_extensible_record() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let release_id = id(@0xBEEF);
    let (mut settings, admin_cap) = settings::new_for_testing(&mut ctx);
    settings.set_witness<DemoWitness>(&admin_cap);
    let mut registry = record::new_registry_for_testing(&mut ctx);
    let registry_id = object::id(&registry);
    let created_at_ms = 1_726_000_123;

    let mut r = mint_record<DemoWitness, SUI>(
        &mut registry,
        &settings,
        demo_witness(),
        release_id,
        created_at_ms,
        &mut ctx,
    );

    assert_eq!(r.release_id(), release_id);
    assert_eq!(r.registry_id(), registry_id);
    assert_eq!(r.number(), 1);
    assert_eq!(r.created_at_ms(), created_at_ms);
    assert_eq!(r.purchase_currency(), type_name::with_defining_ids<SUI>());
    assert_eq!(r.purchased_by(), @0xA);
    assert_eq!(registry.supply(release_id), 1);
    assert_eq!(object::id(&r), record::derive_address(registry_id, release_id, 1).to_id());

    let mut registry_events = event::events_by_type<record::RecordRegistryCreatedEvent>();
    assert_eq!(registry_events.length(), 1);
    assert_eq!(
        record::registry_created_event_fields(registry_events.pop_back()),
        registry_id,
    );

    let mut created_events = event::events_by_type<record::RecordCreatedEvent>();
    assert_eq!(created_events.length(), 1);
    let (
        event_record_id,
        event_registry_id,
        event_release_id,
        number,
        event_created_at_ms,
        purchase_currency,
        purchased_by,
        witness,
    ) = record::record_created_event_fields(created_events.pop_back());
    assert_eq!(event_record_id, object::id(&r));
    assert_eq!(event_registry_id, registry_id);
    assert_eq!(event_release_id, release_id);
    assert_eq!(number, 1);
    assert_eq!(event_created_at_ms, created_at_ms);
    assert_eq!(purchase_currency, type_name::with_defining_ids<SUI>());
    assert_eq!(purchased_by, @0xA);
    assert_eq!(witness, type_name::with_defining_ids<DemoWitness>());

    df::add(r.uid_mut(), DemoKey(), b"extension");
    assert!(df::exists(r.uid(), DemoKey()));
    let _: vector<u8> = df::remove(r.uid_mut(), DemoKey());

    let record_id = object::id(&r);
    r.destroy();
    let mut destroyed_events = event::events_by_type<record::RecordDestroyedEvent>();
    assert_eq!(destroyed_events.length(), 1);
    let (event_record_id, event_release_id) =
        record::record_destroyed_event_fields(destroyed_events.pop_back());
    assert_eq!(event_record_id, record_id);
    assert_eq!(event_release_id, release_id);

    destroy(registry);
    destroy(settings);
    destroy(admin_cap);
}

#[test]
fun registry_allocates_an_independent_sequence_for_each_release() {
    let mut ctx = tx_context::dummy();
    let (mut settings, admin_cap) = settings::new_for_testing(&mut ctx);
    settings.set_witness<DemoWitness>(&admin_cap);
    let mut registry = record::new_registry_for_testing(&mut ctx);
    let registry_id = object::id(&registry);

    let first = mint_record<DemoWitness, SUI>(
        &mut registry,
        &settings,
        demo_witness(),
        id(@0xCAFE),
        0,
        &mut ctx,
    );
    let second = mint_record<DemoWitness, SUI>(
        &mut registry,
        &settings,
        demo_witness(),
        id(@0xBEEF),
        0,
        &mut ctx,
    );
    let third = mint_record<DemoWitness, SUI>(
        &mut registry,
        &settings,
        demo_witness(),
        id(@0xCAFE),
        0,
        &mut ctx,
    );

    assert_eq!(first.number(), 1);
    assert_eq!(second.number(), 1);
    assert_eq!(third.number(), 2);
    assert_eq!(registry.supply(id(@0xCAFE)), 2);
    assert_eq!(registry.supply(id(@0xBEEF)), 1);
    assert_eq!(registry.supply(id(@0xD00D)), 0);
    assert_eq!(
        object::id(&first),
        record::derive_address(registry_id, id(@0xCAFE), 1).to_id(),
    );
    assert_eq!(
        object::id(&second),
        record::derive_address(registry_id, id(@0xBEEF), 1).to_id(),
    );
    assert_eq!(
        object::id(&third),
        record::derive_address(registry_id, id(@0xCAFE), 2).to_id(),
    );

    first.destroy();
    second.destroy();
    third.destroy();
    destroy(registry);
    destroy(settings);
    destroy(admin_cap);
}

#[test]
fun replacing_sales_package_continues_the_registry_sequence() {
    let mut ctx = tx_context::dummy();
    let (mut settings, admin_cap) = settings::new_for_testing(&mut ctx);
    let mut registry = record::new_registry_for_testing(&mut ctx);

    settings.set_witness<DemoWitness>(&admin_cap);
    let first = mint_record<DemoWitness, SUI>(
        &mut registry,
        &settings,
        demo_witness(),
        id(@0xCAFE),
        0,
        &mut ctx,
    );

    settings.set_witness<ReplacementWitness>(&admin_cap);
    let second = mint_record<ReplacementWitness, SUI>(
        &mut registry,
        &settings,
        replacement_witness(),
        id(@0xCAFE),
        0,
        &mut ctx,
    );

    assert_eq!(first.number(), 1);
    assert_eq!(second.number(), 2);
    assert_eq!(first.registry_id(), second.registry_id());

    first.destroy();
    second.destroy();
    destroy(registry);
    destroy(settings);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = record::ENotAuthorized, location = record)]
fun unauthorized_witness_cannot_mint() {
    let mut ctx = tx_context::dummy();
    let (settings, admin_cap) = settings::new_for_testing(&mut ctx);
    let mut registry = record::new_registry_for_testing(&mut ctx);

    let record = mint_record<ImpostorWitness, SUI>(
        &mut registry,
        &settings,
        impostor_witness(),
        id(@0xBEEF),
        0,
        &mut ctx,
    );
    record.destroy();
    destroy(registry);
    destroy(settings);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = record::ENotAuthorized, location = record)]
fun clearing_the_witness_disables_minting() {
    let mut ctx = tx_context::dummy();
    let (mut settings, admin_cap) = settings::new_for_testing(&mut ctx);
    settings.set_witness<DemoWitness>(&admin_cap);
    settings.clear_witness(&admin_cap);
    let mut registry = record::new_registry_for_testing(&mut ctx);

    let record = mint_record<DemoWitness, SUI>(
        &mut registry,
        &settings,
        demo_witness(),
        id(@0xBEEF),
        0,
        &mut ctx,
    );
    record.destroy();
    destroy(registry);
    destroy(settings);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = record::ENotAuthorized, location = record)]
fun replacing_the_witness_immediately_rejects_the_old_sales_package() {
    let mut ctx = tx_context::dummy();
    let (mut settings, admin_cap) = settings::new_for_testing(&mut ctx);
    settings.set_witness<DemoWitness>(&admin_cap);
    settings.set_witness<ReplacementWitness>(&admin_cap);
    let mut registry = record::new_registry_for_testing(&mut ctx);

    let record = mint_record<DemoWitness, SUI>(
        &mut registry,
        &settings,
        demo_witness(),
        id(@0xBEEF),
        0,
        &mut ctx,
    );
    record.destroy();
    destroy(registry);
    destroy(settings);
    destroy(admin_cap);
}

#[test]
fun settings_holds_one_rotatable_witness_and_emits_changes_once() {
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
    assert_eq!(settings.witness(), option::none());

    settings.set_witness<DemoWitness>(&admin_cap);
    settings.set_witness<DemoWitness>(&admin_cap);
    settings.set_witness<ReplacementWitness>(&admin_cap);
    assert!(!settings.is_authorized<DemoWitness>());
    assert!(settings.is_authorized<ReplacementWitness>());
    assert_eq!(
        settings.witness(),
        option::some(type_name::with_defining_ids<ReplacementWitness>()),
    );

    let set_events = event::events_by_type<settings::WitnessSetEvent>();
    assert_eq!(set_events.length(), 2);
    let (event_settings_id, previous, witness) =
        settings::witness_set_event_fields(set_events[0]);
    assert_eq!(event_settings_id, settings_id);
    assert_eq!(previous, option::none());
    assert_eq!(witness, type_name::with_defining_ids<DemoWitness>());
    let (event_settings_id, previous, witness) =
        settings::witness_set_event_fields(set_events[1]);
    assert_eq!(event_settings_id, settings_id);
    assert_eq!(previous, option::some(type_name::with_defining_ids<DemoWitness>()));
    assert_eq!(witness, type_name::with_defining_ids<ReplacementWitness>());

    settings.clear_witness(&admin_cap);
    settings.clear_witness(&admin_cap);
    assert_eq!(settings.witness(), option::none());
    assert!(!settings.is_authorized<ReplacementWitness>());

    let mut cleared_events = event::events_by_type<settings::WitnessClearedEvent>();
    assert_eq!(cleared_events.length(), 1);
    let (event_settings_id, witness) =
        settings::witness_cleared_event_fields(cleared_events.pop_back());
    assert_eq!(event_settings_id, settings_id);
    assert_eq!(witness, type_name::with_defining_ids<ReplacementWitness>());

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
    assert_eq!(settings.witness(), option::none());

    ts::return_shared(settings);
    scenario.return_to_sender(admin_cap);
    scenario.end();
}

#[test]
fun init_shares_the_single_empty_registry() {
    let mut scenario = ts::begin(@0xA);
    record::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xB);
    let registry = scenario.take_shared<RecordRegistry>();
    assert_eq!(registry.supply(id(@0xBEEF)), 0);

    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun record_supports_framework_public_transfer() {
    let mut scenario = ts::begin(@0xA);
    let (mut settings, admin_cap) = settings::new_for_testing(scenario.ctx());
    settings.set_witness<DemoWitness>(&admin_cap);
    let mut registry = record::new_registry_for_testing(scenario.ctx());
    let record = mint_record<DemoWitness, SUI>(
        &mut registry,
        &settings,
        demo_witness(),
        id(@0xBEEF),
        0,
        scenario.ctx(),
    );
    let record_id = object::id(&record);

    destroy(registry);
    destroy(settings);
    destroy(admin_cap);
    transfer::public_transfer(record, @0xB);

    scenario.next_tx(@0xB);
    let received = scenario.take_from_sender<Record>();
    assert_eq!(object::id(&received), record_id);
    received.destroy();

    scenario.end();
}
