// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_record::record_tests;

use miso::release::{Self, Release, ReleaseAdminCap};
use miso_record::pressing::{Self, Pressing};
use miso_record::record::{Self, Record};
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::clock;
use sui::derived_object;
use sui::dynamic_field as df;
use sui::event;
use sui::test_scenario as ts;

/// Stand-in for an authorized distributor package's module-controlled witness.
public struct DemoDistributor() has drop;

/// Stand-in for a replacement or concurrent distributor package.
public struct ReplacementDistributor() has drop;

/// A distributor witness type that is never authorized.
public struct ImpostorDistributor() has drop;

/// Stand-in for an extension's module-private dynamic-field key.
public struct DemoKey() has copy, drop, store;

fun id(addr: address): ID {
    object::id_from_address(addr)
}

fun demo_distributor(): DemoDistributor {
    DemoDistributor()
}

fun replacement_distributor(): ReplacementDistributor {
    ReplacementDistributor()
}

fun impostor_distributor(): ImpostorDistributor {
    ImpostorDistributor()
}

fun a_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    release::new_for_testing("Test", vector[], ctx)
}

fun mint_record<Distributor: drop>(
    pressing: &mut Pressing,
    distributor: Distributor,
    timestamp_ms: u64,
    ctx: &mut TxContext,
): Record {
    let mut clk = clock::create_for_testing(ctx);
    clk.set_for_testing(timestamp_ms);
    let record = pressing.mint(distributor, &clk);
    clk.destroy_for_testing();
    record
}

#[test]
fun authorized_distributor_mints_a_self_describing_extensible_record() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let release_id = id(@0xBEEF);
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(release_id, 2, option::none(), &mut ctx);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    let pressing_id = object::id(&pressing);
    let created_at_ms = 1_726_000_123;

    let mut r = mint_record(
        &mut pressing,
        demo_distributor(),
        created_at_ms,
        &mut ctx,
    );

    assert_eq!(r.release_id(), release_id);
    assert_eq!(r.pressing_id(), pressing_id);
    assert_eq!(r.edition(), 2);
    assert_eq!(r.number(), 1);
    assert_eq!(r.created_at_ms(), created_at_ms);
    assert_eq!(pressing.supply(), 1);
    assert_eq!(pressing.max_supply(), option::none());
    assert!(pressing.is_distributor_authorized<DemoDistributor>());
    assert_eq!(pressing.distributors().length(), 1);
    assert_eq!(object::id(&r), record::derive_id(pressing_id, 1));

    let mut created_events = event::events_by_type<record::RecordCreated>();
    assert_eq!(created_events.length(), 1);
    let (
        event_record_id,
        event_release_id,
        event_pressing_id,
        edition,
        number,
        event_created_at_ms,
        distributor,
    ) = record::created_event_fields(created_events.pop_back());
    assert_eq!(event_record_id, object::id(&r));
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_pressing_id, pressing_id);
    assert_eq!(edition, 2);
    assert_eq!(number, 1);
    assert_eq!(event_created_at_ms, created_at_ms);
    assert_eq!(distributor, type_name::with_defining_ids<DemoDistributor>());

    df::add(r.uid_mut(), DemoKey(), b"extension");
    assert!(df::exists(r.uid(), DemoKey()));
    let _: vector<u8> = df::remove(r.uid_mut(), DemoKey());

    let record_id = object::id(&r);
    r.destroy();
    let mut destroyed_events = event::events_by_type<record::RecordDestroyed>();
    assert_eq!(destroyed_events.length(), 1);
    let (event_record_id, event_pressing_id) =
        record::destroyed_event_fields(destroyed_events.pop_back());
    assert_eq!(event_record_id, record_id);
    assert_eq!(event_pressing_id, pressing_id);

    destroy(pressing);
    destroy(admin_cap);
}

#[test]
fun pressings_allocate_edition_local_sequences() {
    let mut ctx = tx_context::dummy();
    let release_id = id(@0xCAFE);
    let (mut first_pressing, first_cap) =
        pressing::new_for_testing(release_id, 1, option::none(), &mut ctx);
    let (mut second_pressing, second_cap) =
        pressing::new_for_testing(release_id, 2, option::none(), &mut ctx);
    first_pressing.authorize_distributor<DemoDistributor>(&first_cap);
    second_pressing.authorize_distributor<DemoDistributor>(&second_cap);

    let first = mint_record(&mut first_pressing, demo_distributor(), 0, &mut ctx);
    let second = mint_record(&mut second_pressing, demo_distributor(), 0, &mut ctx);
    let third = mint_record(&mut first_pressing, demo_distributor(), 0, &mut ctx);

    assert_eq!(first.number(), 1);
    assert_eq!(second.number(), 1);
    assert_eq!(third.number(), 2);
    assert_eq!(first.edition(), 1);
    assert_eq!(second.edition(), 2);
    assert_eq!(first_pressing.supply(), 2);
    assert_eq!(second_pressing.supply(), 1);
    assert_eq!(object::id(&first), record::derive_id(object::id(&first_pressing), 1));
    assert_eq!(object::id(&second), record::derive_id(object::id(&second_pressing), 1));
    assert_eq!(object::id(&third), record::derive_id(object::id(&first_pressing), 2));

    first.destroy();
    second.destroy();
    third.destroy();
    destroy(first_pressing);
    destroy(first_cap);
    destroy(second_pressing);
    destroy(second_cap);
}

#[test]
fun distributor_replacement_continues_the_pressing_sequence() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xCAFE), 1, option::none(), &mut ctx);

    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    let first = mint_record(&mut pressing, demo_distributor(), 0, &mut ctx);

    pressing.authorize_distributor<ReplacementDistributor>(&admin_cap);
    let second = mint_record(&mut pressing, replacement_distributor(), 0, &mut ctx);
    pressing.revoke_distributor<DemoDistributor>(&admin_cap);
    pressing.revoke_distributor<DemoDistributor>(&admin_cap);
    let third = mint_record(&mut pressing, replacement_distributor(), 0, &mut ctx);

    assert_eq!(first.number(), 1);
    assert_eq!(second.number(), 2);
    assert_eq!(third.number(), 3);
    assert_eq!(pressing.distributors().length(), 1);
    assert!(!pressing.is_distributor_authorized<DemoDistributor>());
    assert!(pressing.is_distributor_authorized<ReplacementDistributor>());

    let authorized = event::events_by_type<pressing::DistributorAuthorized>();
    assert_eq!(authorized.length(), 2);
    let revoked = event::events_by_type<pressing::DistributorRevoked>();
    assert_eq!(revoked.length(), 1);

    first.destroy();
    second.destroy();
    third.destroy();
    destroy(pressing);
    destroy(admin_cap);
}

#[test, expected_failure(
    abort_code = pressing::EDistributorNotAuthorized,
    location = pressing,
)]
fun unauthorized_distributor_cannot_mint() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, option::none(), &mut ctx);
    let record = mint_record(&mut pressing, impostor_distributor(), 0, &mut ctx);
    record.destroy();
    destroy(pressing);
    destroy(admin_cap);
}

#[test, expected_failure(
    abort_code = pressing::EDistributorNotAuthorized,
    location = pressing,
)]
fun revoked_distributor_cannot_mint() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, option::none(), &mut ctx);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    pressing.revoke_distributor<DemoDistributor>(&admin_cap);
    let record = mint_record(&mut pressing, demo_distributor(), 0, &mut ctx);
    record.destroy();
    destroy(pressing);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = pressing::EMaxSupplyReached, location = pressing)]
fun capped_pressing_rejects_the_next_record_after_its_maximum() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, option::some(2), &mut ctx);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    let first = mint_record(&mut pressing, demo_distributor(), 0, &mut ctx);
    let second = mint_record(&mut pressing, demo_distributor(), 0, &mut ctx);
    first.destroy();
    second.destroy();
    let record = mint_record(&mut pressing, demo_distributor(), 0, &mut ctx);
    record.destroy();
    destroy(pressing);
    destroy(admin_cap);
}

#[test]
fun release_derives_one_pressing_per_edition() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut release, release_cap) = a_release(&mut ctx);
    let release_id = object::id(&release);

    let (first, first_cap) = pressing::new(
        &mut release,
        &release_cap,
        1,
        option::none(),
    );
    let (second, second_cap) = pressing::new(
        &mut release,
        &release_cap,
        2,
        option::some(500),
    );

    assert_eq!(object::id(&first), pressing::derive_id(release_id, 1));
    assert_eq!(object::id(&second), pressing::derive_id(release_id, 2));
    assert_eq!(object::id(&first_cap), pressing::derive_admin_cap_id(object::id(&first)));
    assert_eq!(first_cap.pressing_id(), object::id(&first));
    assert_eq!(first.release_id(), release_id);
    assert_eq!(first.edition(), 1);
    assert_eq!(first.max_supply(), option::none());
    assert_eq!(second.edition(), 2);
    assert_eq!(second.max_supply(), option::some(500));

    let created = event::events_by_type<pressing::PressingCreated>();
    assert_eq!(created.length(), 2);
    let (pressing_id, event_release_id, edition, max_supply) =
        pressing::created_event_fields(created[1]);
    assert_eq!(pressing_id, object::id(&second));
    assert_eq!(event_release_id, release_id);
    assert_eq!(edition, 2);
    assert_eq!(max_supply, option::some(500));

    destroy(first);
    destroy(first_cap);
    destroy(second);
    destroy(second_cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(
    abort_code = derived_object::EObjectAlreadyExists,
    location = derived_object,
)]
fun release_cannot_create_the_same_edition_twice() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let (first, first_cap) = pressing::new(
        &mut release,
        &release_cap,
        1,
        option::none(),
    );
    let (second, second_cap) = pressing::new(
        &mut release,
        &release_cap,
        1,
        option::none(),
    );
    destroy(first);
    destroy(first_cap);
    destroy(second);
    destroy(second_cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = pressing::EUnauthorized, location = pressing)]
fun distributor_authorization_requires_the_matching_pressing_cap() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, option::none(), &mut ctx);
    let foreign_cap = pressing::foreign_admin_cap_for_testing(id(@0xDEAD), &mut ctx);
    pressing.authorize_distributor<DemoDistributor>(&foreign_cap);
    destroy(pressing);
    destroy(admin_cap);
    destroy(foreign_cap);
}

#[test, expected_failure(abort_code = pressing::EWrongVersion, location = pressing)]
fun stale_pressing_rejects_distributor_authorization() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, option::none(), &mut ctx);
    pressing.set_version_for_testing(0);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    destroy(pressing);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = pressing::EWrongVersion, location = pressing)]
fun stale_pressing_rejects_minting() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, option::none(), &mut ctx);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    pressing.set_version_for_testing(0);
    let record = mint_record(&mut pressing, demo_distributor(), 0, &mut ctx);
    record.destroy();
    destroy(pressing);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = pressing::EWrongVersion, location = pressing)]
fun stale_pressing_rejects_mutable_uid_access() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, option::none(), &mut ctx);
    pressing.set_version_for_testing(0);
    let _uid = pressing.uid_mut(&admin_cap);
    destroy(pressing);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = pressing::EInvalidEdition, location = pressing)]
fun edition_zero_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let (pressing, pressing_cap) =
        pressing::new(&mut release, &release_cap, 0, option::none());
    destroy(pressing);
    destroy(pressing_cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = pressing::EInvalidMaxSupply, location = pressing)]
fun capped_pressing_rejects_zero_maximum() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let (pressing, pressing_cap) =
        pressing::new(&mut release, &release_cap, 1, option::some(0));
    destroy(pressing);
    destroy(pressing_cap);
    destroy(release);
    destroy(release_cap);
}

#[test]
fun record_supports_framework_public_transfer() {
    let mut scenario = ts::begin(@0xA);
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, option::none(), scenario.ctx());
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    let record = mint_record(&mut pressing, demo_distributor(), 0, scenario.ctx());
    let record_id = object::id(&record);

    destroy(pressing);
    destroy(admin_cap);
    transfer::public_transfer(record, @0xB);

    scenario.next_tx(@0xB);
    let received = scenario.take_from_sender<Record>();
    assert_eq!(object::id(&received), record_id);
    received.destroy();

    scenario.end();
}
