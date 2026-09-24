// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module record::record_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use record::pressing::{Self, Pressing};
use record::record::{Self, Record};
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

/// Stand-in for the currency used to purchase Records.
public struct USD() has drop;

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
    purchase_price: u64,
    timestamp_ms: u64,
    ctx: &mut TxContext,
): Record {
    let mut clk = clock::create_for_testing(ctx);
    clk.set_for_testing(timestamp_ms);
    let record = pressing.mint<Distributor, USD>(distributor, purchase_price, &clk);
    clk.destroy_for_testing();
    record
}

#[test]
fun authorized_distributor_mints_a_self_describing_extensible_record() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let release_id = id(@0xBEEF);
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(release_id, 2, 100, &mut ctx);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    let pressing_id = object::id(&pressing);
    let purchase_price = 25;
    let purchased_at_ms = 1_726_000_123;

    let mut r = mint_record(
        &mut pressing,
        demo_distributor(),
        purchase_price,
        purchased_at_ms,
        &mut ctx,
    );

    assert_eq!(r.release_id(), release_id);
    assert_eq!(r.pressing_id(), pressing_id);
    assert_eq!(r.edition(), 2);
    assert_eq!(r.number(), 1);
    assert_eq!(r.purchase_currency(), type_name::with_defining_ids<USD>());
    assert_eq!(r.purchase_price(), purchase_price);
    assert_eq!(r.purchased_at_ms(), purchased_at_ms);
    assert_eq!(pressing.supply(), 1);
    assert_eq!(pressing.max_supply(), 100);
    assert!(pressing.is_distributor_authorized<DemoDistributor>());
    assert_eq!(pressing.distributors().length(), 1);
    assert_eq!(object::id_address(&r), record::derive_address(pressing_id, 1));

    let mut purchased_events =
        event::events_by_type<pressing::RecordPurchasedEvent<DemoDistributor, USD>>();
    assert_eq!(purchased_events.length(), 1);
    let (
        event_record_id,
        event_release_id,
        event_pressing_id,
        edition,
        number,
        event_purchase_price,
        event_purchased_at_ms,
        _,
        _,
        _,
        _,
    ) = pressing::purchased_event_fields(purchased_events.pop_back());
    assert_eq!(event_record_id, object::id(&r).to_address());
    assert_eq!(event_release_id, release_id.to_address());
    assert_eq!(event_pressing_id, pressing_id.to_address());
    assert_eq!(edition, 2);
    assert_eq!(number, 1);
    assert_eq!(event_purchase_price, purchase_price);
    assert_eq!(event_purchased_at_ms, purchased_at_ms);

    df::add(r.uid_mut(), DemoKey(), b"extension");
    assert!(df::exists(r.uid(), DemoKey()));
    let _: vector<u8> = df::remove(r.uid_mut(), DemoKey());

    let record_id = object::id(&r);
    r.destroy();
    let mut destroyed_events = event::events_by_type<record::RecordDestroyedEvent>();
    assert_eq!(destroyed_events.length(), 1);
    let destroyed_event = destroyed_events.pop_back();
    // Three addresses, one u16 and one u32: no duplicated purchase provenance.
    assert_eq!(std::bcs::to_bytes(&destroyed_event).length(), 102);
    let (event_record_id, _, event_pressing_id, _, _) =
        record::destroyed_event_fields(destroyed_event);
    assert_eq!(event_record_id, record_id.to_address());
    assert_eq!(event_pressing_id, pressing_id.to_address());

    destroy(pressing);
    destroy(admin_cap);
}

#[test]
fun pressings_allocate_edition_local_sequences() {
    let mut ctx = tx_context::dummy();
    let release_id = id(@0xCAFE);
    let (mut first_pressing, first_cap) =
        pressing::new_for_testing(release_id, 1, 100, &mut ctx);
    let (mut second_pressing, second_cap) =
        pressing::new_for_testing(release_id, 2, 100, &mut ctx);
    first_pressing.authorize_distributor<DemoDistributor>(&first_cap);
    second_pressing.authorize_distributor<DemoDistributor>(&second_cap);

    let first = mint_record(&mut first_pressing, demo_distributor(), 1, 0, &mut ctx);
    let second = mint_record(&mut second_pressing, demo_distributor(), 1, 0, &mut ctx);
    let third = mint_record(&mut first_pressing, demo_distributor(), 1, 0, &mut ctx);

    assert_eq!(first.number(), 1);
    assert_eq!(second.number(), 1);
    assert_eq!(third.number(), 2);
    assert_eq!(first.edition(), 1);
    assert_eq!(second.edition(), 2);
    assert_eq!(first_pressing.supply(), 2);
    assert_eq!(second_pressing.supply(), 1);
    assert_eq!(object::id_address(&first), record::derive_address(object::id(&first_pressing), 1));
    assert_eq!(object::id_address(&second), record::derive_address(object::id(&second_pressing), 1));
    assert_eq!(object::id_address(&third), record::derive_address(object::id(&first_pressing), 2));

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
        pressing::new_for_testing(id(@0xCAFE), 1, 100, &mut ctx);

    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    let first = mint_record(&mut pressing, demo_distributor(), 1, 0, &mut ctx);

    pressing.authorize_distributor<ReplacementDistributor>(&admin_cap);
    let second = mint_record(&mut pressing, replacement_distributor(), 1, 0, &mut ctx);
    pressing.revoke_distributor<DemoDistributor>(&admin_cap);
    pressing.revoke_distributor<DemoDistributor>(&admin_cap);
    let third = mint_record(&mut pressing, replacement_distributor(), 1, 0, &mut ctx);

    assert_eq!(first.number(), 1);
    assert_eq!(second.number(), 2);
    assert_eq!(third.number(), 3);
    assert_eq!(pressing.distributors().length(), 1);
    assert!(!pressing.is_distributor_authorized<DemoDistributor>());
    assert!(pressing.is_distributor_authorized<ReplacementDistributor>());

    let mut authorized =
        event::events_by_type<pressing::PressingDistributorAuthorizedEvent<DemoDistributor>>();
    assert_eq!(authorized.length(), 1);
    let (_, _, _, _, _, _, _, _) =
        pressing::pressing_distributor_authorized_event_fields(authorized.pop_back());

    let mut replacement_authorized = event::events_by_type<
        pressing::PressingDistributorAuthorizedEvent<ReplacementDistributor>,
    >();
    assert_eq!(replacement_authorized.length(), 1);
    let (_, _, _, _, _, _, _, _) =
        pressing::pressing_distributor_authorized_event_fields(replacement_authorized.pop_back());

    let mut revoked = event::events_by_type<
        pressing::PressingDistributorRevokedEvent<DemoDistributor>,
    >();
    assert_eq!(revoked.length(), 1);
    let (_, _, _, _, _, _, _, _) =
        pressing::pressing_distributor_revoked_event_fields(revoked.pop_back());

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
        pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut ctx);
    let record = mint_record(&mut pressing, impostor_distributor(), 1, 0, &mut ctx);
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
        pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut ctx);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    pressing.revoke_distributor<DemoDistributor>(&admin_cap);
    let record = mint_record(&mut pressing, demo_distributor(), 1, 0, &mut ctx);
    record.destroy();
    destroy(pressing);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = pressing::EMaxSupplyReached, location = pressing)]
fun capped_pressing_rejects_the_next_record_after_its_maximum() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, 2, &mut ctx);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    let first = mint_record(&mut pressing, demo_distributor(), 1, 0, &mut ctx);
    let second = mint_record(&mut pressing, demo_distributor(), 1, 0, &mut ctx);
    first.destroy();
    second.destroy();
    let record = mint_record(&mut pressing, demo_distributor(), 1, 0, &mut ctx);
    record.destroy();
    destroy(pressing);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = pressing::EInvalidPurchasePrice, location = pressing)]
fun authorized_distributor_cannot_purchase_a_zero_price_record() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut ctx);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    let record = mint_record(&mut pressing, demo_distributor(), 0, 0, &mut ctx);
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
        100,
    );
    let (second, second_cap) = pressing::new(
        &mut release,
        &release_cap,
        2,
        500,
    );

    assert_eq!(object::id_address(&first), pressing::derive_address(release_id, 1));
    assert_eq!(object::id_address(&second), pressing::derive_address(release_id, 2));
    assert_eq!(
        object::id_address(&first_cap),
        pressing::derive_admin_cap_address(object::id(&first)),
    );
    assert_eq!(first_cap.pressing_id(), object::id(&first));
    assert_eq!(first.release_id(), release_id);
    assert_eq!(first.edition(), 1);
    assert_eq!(first.max_supply(), 100);
    assert_eq!(second.edition(), 2);
    assert_eq!(second.max_supply(), 500);

    let created = event::events_by_type<pressing::PressingCreatedEvent>();
    assert_eq!(created.length(), 2);
    let (
        pressing_id,
        event_release_id,
        _,
        _,
        edition,
        _,
        max_supply,
        _,
    ) =
        pressing::created_event_fields(created[1]);
    assert_eq!(pressing_id, object::id(&second).to_address());
    assert_eq!(event_release_id, release_id.to_address());
    assert_eq!(edition, 2);
    assert_eq!(max_supply, 500);

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
        100,
    );
    let (second, second_cap) = pressing::new(
        &mut release,
        &release_cap,
        1,
        100,
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
        pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut ctx);
    let foreign_cap = pressing::foreign_admin_cap_for_testing(id(@0xDEAD), &mut ctx);
    pressing.authorize_distributor<DemoDistributor>(&foreign_cap);
    destroy(pressing);
    destroy(admin_cap);
    destroy(foreign_cap);
}

#[test, expected_failure(abort_code = pressing::EInvalidEdition, location = pressing)]
fun edition_zero_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let (pressing, pressing_cap) =
        pressing::new(&mut release, &release_cap, 0, 100);
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
        pressing::new(&mut release, &release_cap, 1, 0);
    destroy(pressing);
    destroy(pressing_cap);
    destroy(release);
    destroy(release_cap);
}

#[test]
fun record_supports_framework_public_transfer() {
    let mut scenario = ts::begin(@0xA);
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, 100, scenario.ctx());
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    let record = mint_record(&mut pressing, demo_distributor(), 1, 0, scenario.ctx());
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

#[test]
fun pressing_supports_extensions_before_becoming_shared() {
    let mut scenario = ts::begin(@0xA);
    let (mut pressing, admin_cap) = pressing::new_for_testing(
        id(@0xBEEF),
        1,
        100,
        scenario.ctx(),
    );
    df::add(pressing.uid_mut(&admin_cap), DemoKey(), b"extension");
    assert!(df::exists(pressing.uid(), DemoKey()));
    let _: vector<u8> = df::remove(pressing.uid_mut(&admin_cap), DemoKey());

    destroy(admin_cap);
    let event_count = event::num_events();
    pressing.share();
    assert_eq!(event::num_events(), event_count);

    scenario.next_tx(@0xB);
    let pressing = scenario.take_shared<Pressing>();
    assert_eq!(pressing.edition(), 1);
    ts::return_shared(pressing);
    scenario.end();
}

#[test, expected_failure(abort_code = pressing::EPreviousEditionMissing, location = pressing)]
fun first_edition_cannot_be_skipped() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let (p, cap) = pressing::new(&mut release, &release_cap, 2, 10);
    destroy(p);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = pressing::EPreviousEditionMissing, location = pressing)]
fun intermediate_edition_cannot_be_skipped() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let (first, cap) = pressing::new(&mut release, &release_cap, 1, 10);
    destroy(first);
    destroy(cap);
    let (p, cap) = pressing::new(&mut release, &release_cap, 3, 10);
    destroy(p);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = pressing::EPreviousEditionMissing, location = pressing)]
fun predecessor_must_belong_to_the_same_release() {
    let mut ctx = tx_context::dummy();
    let (mut first_release, first_release_cap) = a_release(&mut ctx);
    let (p, cap) = pressing::new(&mut first_release, &first_release_cap, 1, 10);
    destroy(p);
    destroy(cap);
    let (mut other_release, other_release_cap) = a_release(&mut ctx);
    let (p, cap) = pressing::new(&mut other_release, &other_release_cap, 2, 10);
    destroy(p);
    destroy(cap);
    destroy(first_release);
    destroy(first_release_cap);
    destroy(other_release);
    destroy(other_release_cap);
}

#[test, expected_failure(abort_code = pressing::EMaxSupplyReached, location = pressing)]
fun distributor_rotation_cannot_reset_the_supply_cap() {
    let mut ctx = tx_context::dummy();
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 1, &mut ctx);
    p.authorize_distributor<DemoDistributor>(&cap);
    mint_record(&mut p, demo_distributor(), 1, 0, &mut ctx).destroy();
    p.revoke_distributor<DemoDistributor>(&cap);
    p.authorize_distributor<ReplacementDistributor>(&cap);
    mint_record(&mut p, replacement_distributor(), 1, 0, &mut ctx).destroy();
    destroy(p);
    destroy(cap);
}

#[test]
fun boundary_editions_preserve_record_and_event_provenance() {
    let mut ctx = tx_context::dummy();
    vector[1u16, 65_535u16].do!(|edition| {
        let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), edition, 1, &mut ctx);
        p.authorize_distributor<DemoDistributor>(&cap);
        let r = mint_record(&mut p, demo_distributor(), 1, 0, &mut ctx);
        assert_eq!(p.edition(), edition);
        assert_eq!(r.edition(), edition);
        let mut events = event::events_by_type<pressing::RecordPurchasedEvent<DemoDistributor, USD>>();
        let (_, _, _, event_edition, _, _, _, _, _, _, _) =
            pressing::purchased_event_fields(events.pop_back());
        assert_eq!(event_edition, edition);
        r.destroy();
        let mut events = event::events_by_type<record::RecordDestroyedEvent>();
        let (_, _, _, event_edition, _) =
            record::destroyed_event_fields(events.pop_back());
        assert_eq!(event_edition, edition);
        destroy(p);
        destroy(cap);
    });
}

#[test, expected_failure(abort_code = pressing::EPreviousEditionMissing, location = pressing)]
fun maximum_edition_still_requires_its_predecessor() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let (p, cap) = pressing::new(&mut release, &release_cap, 65_535, 1);
    destroy(p);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}
