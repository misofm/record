// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

#[test_only]
module record::record_tests;

use std::{type_name, u32, u64, unit_test::{assert_eq, destroy}};
use sui::{clock, derived_object, dynamic_field as df, event, test_scenario as ts};
use miso_music::release::{Self, Release, ReleaseAdminCap};
use record::{pressing::{Self, Pressing}, record::{Self, Record}};

const PURCHASED_AT_MS: u64 = 1_726_000_123;

public struct DemoDistributor() has drop;

public struct ReplacementDistributor() has drop;

public struct ImpostorDistributor() has drop;

public struct USD() has drop;

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
    release::new_for_testing(vector[], ctx)
}

fun press_record<Distributor: drop>(
    pressing: &mut Pressing,
    distributor: Distributor,
    purchase_price: u64,
): Record {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(PURCHASED_AT_MS);
    let record = pressing.press<Distributor, USD>(distributor, purchase_price, &clock);
    clock.destroy_for_testing();
    record
}

#[test]
fun authorized_distributor_presses_a_self_describing_extensible_record() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let release_id = id(@0xBEEF);
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(release_id, 2, 100, &mut ctx);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    let pressing_id = object::id(&pressing);
    let purchase_price = 25;
    let mut r = press_record(&mut pressing, demo_distributor(), purchase_price);

    assert_eq!(r.release_id(), release_id);
    assert_eq!(r.pressing_id(), pressing_id);
    assert_eq!(r.edition(), 2);
    assert_eq!(r.number(), 1);
    assert_eq!(r.purchase_currency(), type_name::with_defining_ids<USD>());
    assert_eq!(r.purchase_price(), purchase_price);
    assert_eq!(r.purchased_at_ms(), PURCHASED_AT_MS);
    assert_eq!(pressing.supply(), 1);
    assert_eq!(pressing.max_supply(), 100);
    assert!(pressing.is_distributor_authorized<DemoDistributor>());
    assert_eq!(object::id_address(&r), record::derive_address(pressing_id, 1));

    let mut purchased_events =
        event::events_by_type<pressing::RecordPurchasedEvent<DemoDistributor, USD>>();
    assert_eq!(purchased_events.length(), 1);
    let (event_record_id, event_pressing_id, number, event_purchase_price, purchased_at_ms) =
        pressing::purchased_event_fields(&purchased_events.pop_back());
    assert_eq!(event_record_id, object::id(&r));
    assert_eq!(event_pressing_id, pressing_id);
    assert_eq!(number, 1);
    assert_eq!(event_purchase_price, purchase_price);
    assert_eq!(purchased_at_ms, PURCHASED_AT_MS);

    df::add(r.uid_mut(), DemoKey(), b"extension");
    assert!(df::exists(r.uid(), DemoKey()));
    let _: vector<u8> = df::remove(r.uid_mut(), DemoKey());

    let record_id = object::id(&r);
    r.destroy();
    let mut destroyed_events = event::events_by_type<record::RecordDestroyedEvent>();
    assert_eq!(destroyed_events.length(), 1);
    assert_eq!(record::destroyed_event_record_id(&destroyed_events.pop_back()), record_id);

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

    let first = press_record(&mut first_pressing, demo_distributor(), 1);
    let second = press_record(&mut second_pressing, demo_distributor(), 1);
    let third = press_record(&mut first_pressing, demo_distributor(), 1);

    assert_eq!(first.number(), 1);
    assert_eq!(second.number(), 1);
    assert_eq!(third.number(), 2);
    assert_eq!(first.edition(), 1);
    assert_eq!(second.edition(), 2);
    assert_eq!(first_pressing.supply(), 2);
    assert_eq!(second_pressing.supply(), 1);
    let first_pressing_id = object::id(&first_pressing);
    let second_pressing_id = object::id(&second_pressing);
    assert_eq!(object::id_address(&first), record::derive_address(first_pressing_id, 1));
    assert_eq!(object::id_address(&second), record::derive_address(second_pressing_id, 1));
    assert_eq!(object::id_address(&third), record::derive_address(first_pressing_id, 2));

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
    let first = press_record(&mut pressing, demo_distributor(), 1);

    pressing.authorize_distributor<ReplacementDistributor>(&admin_cap);
    let second = press_record(&mut pressing, replacement_distributor(), 1);
    pressing.revoke_distributor<DemoDistributor>(&admin_cap);
    pressing.revoke_distributor<DemoDistributor>(&admin_cap);
    let third = press_record(&mut pressing, replacement_distributor(), 1);

    assert_eq!(first.number(), 1);
    assert_eq!(second.number(), 2);
    assert_eq!(third.number(), 3);
    assert!(!pressing.is_distributor_authorized<DemoDistributor>());
    assert!(pressing.is_distributor_authorized<ReplacementDistributor>());

    let pressing_id = object::id(&pressing);
    let authorized =
        event::events_by_type<pressing::PressingDistributorAuthorizedEvent<DemoDistributor>>();
    assert_eq!(authorized.length(), 1);
    assert_eq!(pressing::authorized_event_pressing_id(&authorized[0]), pressing_id);

    let replacement_authorized = event::events_by_type<
        pressing::PressingDistributorAuthorizedEvent<ReplacementDistributor>,
    >();
    assert_eq!(replacement_authorized.length(), 1);
    assert_eq!(pressing::authorized_event_pressing_id(&replacement_authorized[0]), pressing_id);

    let revoked = event::events_by_type<
        pressing::PressingDistributorRevokedEvent<DemoDistributor>,
    >();
    assert_eq!(revoked.length(), 1);
    assert_eq!(pressing::revoked_event_pressing_id(&revoked[0]), pressing_id);

    first.destroy();
    second.destroy();
    third.destroy();
    destroy(pressing);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = pressing::EDistributorNotAuthorized)]
fun unauthorized_distributor_cannot_press() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut ctx);
    let record = press_record(&mut pressing, impostor_distributor(), 1);
    record.destroy();
    destroy(pressing);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = pressing::EDistributorNotAuthorized)]
fun revoked_distributor_cannot_press() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut ctx);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    pressing.revoke_distributor<DemoDistributor>(&admin_cap);
    let record = press_record(&mut pressing, demo_distributor(), 1);
    record.destroy();
    destroy(pressing);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = pressing::EMaxSupplyReached)]
fun capped_pressing_rejects_the_next_record_after_its_maximum() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, 2, &mut ctx);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    let first = press_record(&mut pressing, demo_distributor(), 1);
    let second = press_record(&mut pressing, demo_distributor(), 1);
    first.destroy();
    second.destroy();
    let record = press_record(&mut pressing, demo_distributor(), 1);
    record.destroy();
    destroy(pressing);
    destroy(admin_cap);
}

#[test]
fun authorized_distributor_presses_a_free_record() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut ctx);
    pressing.authorize_distributor<DemoDistributor>(&admin_cap);
    let record = press_record(&mut pressing, demo_distributor(), 0);
    assert_eq!(record.purchase_price(), 0);
    assert_eq!(record.number(), 1);
    assert_eq!(pressing.supply(), 1);
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
    let (pressing_id, pressing_admin_cap_id, event_release_id, edition, max_supply) =
        pressing::created_event_fields(&created[1]);
    assert_eq!(pressing_id, object::id(&second));
    assert_eq!(pressing_admin_cap_id, object::id(&second_cap));
    assert_eq!(event_release_id, release_id);
    assert_eq!(edition, 2);
    assert_eq!(max_supply, 500);

    destroy(first);
    destroy(first_cap);
    destroy(second);
    destroy(second_cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = derived_object::EObjectAlreadyExists)]
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

#[test, expected_failure(abort_code = pressing::EUnauthorized)]
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

#[test, expected_failure(abort_code = pressing::EInvalidEdition)]
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

#[test, expected_failure(abort_code = pressing::EInvalidMaxSupply)]
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
    let record = press_record(&mut pressing, demo_distributor(), 1);
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

#[test, expected_failure(abort_code = pressing::EPreviousEditionMissing)]
fun first_edition_cannot_be_skipped() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let (p, cap) = pressing::new(&mut release, &release_cap, 2, 10);
    destroy(p);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = pressing::EPreviousEditionMissing)]
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

#[test, expected_failure(abort_code = pressing::EPreviousEditionMissing)]
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

#[test, expected_failure(abort_code = pressing::EMaxSupplyReached)]
fun distributor_rotation_cannot_reset_the_supply_cap() {
    let mut ctx = tx_context::dummy();
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 1, &mut ctx);
    p.authorize_distributor<DemoDistributor>(&cap);
    press_record(&mut p, demo_distributor(), 1).destroy();
    p.revoke_distributor<DemoDistributor>(&cap);
    p.authorize_distributor<ReplacementDistributor>(&cap);
    press_record(&mut p, replacement_distributor(), 1).destroy();
    destroy(p);
    destroy(cap);
}

#[test]
fun boundary_editions_preserve_record_and_event_provenance() {
    let mut ctx = tx_context::dummy();
    vector[1u16, 65_535u16].do!(|edition| {
        let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), edition, 1, &mut ctx);
        p.authorize_distributor<DemoDistributor>(&cap);
        let r = press_record(&mut p, demo_distributor(), 1);
        assert_eq!(p.edition(), edition);
        assert_eq!(r.edition(), edition);
        let mut events =
            event::events_by_type<pressing::RecordPurchasedEvent<DemoDistributor, USD>>();
        let (_, event_pressing_id, _, _, _) =
            pressing::purchased_event_fields(&events.pop_back());
        assert_eq!(event_pressing_id, object::id(&p));
        r.destroy();
        destroy(p);
        destroy(cap);
    });
}

#[test, expected_failure(abort_code = pressing::EPreviousEditionMissing)]
fun maximum_edition_still_requires_its_predecessor() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let (p, cap) = pressing::new(&mut release, &release_cap, 65_535, 1);
    destroy(p);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = pressing::EUnauthorized)]
fun uid_mut_requires_the_matching_pressing_cap() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, admin_cap) =
        pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut ctx);
    let foreign_cap = pressing::foreign_admin_cap_for_testing(id(@0xDEAD), &mut ctx);
    let _ = pressing.uid_mut(&foreign_cap);
    destroy(pressing);
    destroy(admin_cap);
    destroy(foreign_cap);
}

#[test, expected_failure(abort_code = release::EUnauthorized)]
fun pressing_requires_the_matching_release_cap() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let (other_release, other_cap) = a_release(&mut ctx);
    let (p, cap) = pressing::new(&mut release, &other_cap, 1, 10);
    destroy(p);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
    destroy(other_release);
    destroy(other_cap);
}

#[test]
fun published_release_derives_a_pressing() {
    let mut scenario = ts::begin(@0xA);
    let (release, release_cap) = a_release(scenario.ctx());
    let release_id = object::id(&release);
    release.publish(&release_cap);

    scenario.next_tx(@0xA);
    let mut release = scenario.take_shared<Release>();
    let (p, cap) = pressing::new(&mut release, &release_cap, 1, 10);
    assert_eq!(object::id_address(&p), pressing::derive_address(release_id, 1));
    assert_eq!(p.release_id(), release_id);
    ts::return_shared(release);
    destroy(p);
    destroy(cap);
    destroy(release_cap);
    scenario.end();
}

#[test]
fun maximum_supply_is_accepted_and_pressable() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let (p, cap) = pressing::new(&mut release, &release_cap, 1, u32::max_value!());
    assert_eq!(p.max_supply(), u32::max_value!());
    destroy(p);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test]
fun record_presses_up_to_the_maximum_supply() {
    let mut ctx = tx_context::dummy();
    let max = u32::max_value!();
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, max, &mut ctx);
    p.authorize_distributor<DemoDistributor>(&cap);
    p.set_supply_for_testing(max - 1);
    let r = press_record(&mut p, demo_distributor(), 1);
    assert_eq!(r.number(), max);
    assert_eq!(p.supply(), max);
    r.destroy();
    destroy(p);
    destroy(cap);
}

#[test, expected_failure(abort_code = pressing::EMaxSupplyReached)]
fun maximum_supply_rejects_the_next_record() {
    let mut ctx = tx_context::dummy();
    let max = u32::max_value!();
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, max, &mut ctx);
    p.authorize_distributor<DemoDistributor>(&cap);
    p.set_supply_for_testing(max);
    press_record(&mut p, demo_distributor(), 1).destroy();
    destroy(p);
    destroy(cap);
}

#[test]
fun maximum_purchase_price_is_stored() {
    let mut ctx = tx_context::dummy();
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 1, &mut ctx);
    p.authorize_distributor<DemoDistributor>(&cap);
    let r = press_record(&mut p, demo_distributor(), u64::max_value!());
    assert_eq!(r.purchase_price(), u64::max_value!());
    r.destroy();
    destroy(p);
    destroy(cap);
}

#[test]
fun shared_pressing_presses_the_next_record() {
    let mut scenario = ts::begin(@0xA);
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 10, scenario.ctx());
    p.authorize_distributor<DemoDistributor>(&cap);
    let pressing_id = object::id(&p);
    p.share();

    scenario.next_tx(@0xB);
    let mut p = scenario.take_shared<Pressing>();
    let r = press_record(&mut p, demo_distributor(), 3);
    assert_eq!(r.number(), 1);
    assert_eq!(object::id_address(&r), record::derive_address(pressing_id, 1));
    assert_eq!(p.supply(), 1);
    ts::return_shared(p);
    r.destroy();
    destroy(cap);
    scenario.end();
}

#[test]
fun release_to_record_derivation_chain() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let release_id = object::id(&release);
    let (mut p, cap) = pressing::new(&mut release, &release_cap, 1, 10);
    p.authorize_distributor<DemoDistributor>(&cap);
    let pressing_id = object::id(&p);
    assert_eq!(pressing_id.to_address(), pressing::derive_address(release_id, 1));
    let first = press_record(&mut p, demo_distributor(), 1);
    let second = press_record(&mut p, demo_distributor(), 1);
    assert_eq!(object::id_address(&first), record::derive_address(pressing_id, 1));
    assert_eq!(object::id_address(&second), record::derive_address(pressing_id, 2));
    assert_eq!(first.release_id(), release_id);
    assert_eq!(first.pressing_id(), pressing_id);
    first.destroy();
    second.destroy();
    destroy(p);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test]
fun revoking_one_of_two_distributors_keeps_the_other() {
    let mut ctx = tx_context::dummy();
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 10, &mut ctx);
    p.authorize_distributor<DemoDistributor>(&cap);
    p.authorize_distributor<ReplacementDistributor>(&cap);
    p.revoke_distributor<DemoDistributor>(&cap);
    assert!(!p.is_distributor_authorized<DemoDistributor>());
    assert!(p.is_distributor_authorized<ReplacementDistributor>());
    assert!(!p.is_distributor_authorized<ImpostorDistributor>());
    destroy(p);
    destroy(cap);
}

#[test]
fun distributors_view_lists_authorized_types() {
    let mut ctx = tx_context::dummy();
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 10, &mut ctx);
    assert!(p.distributors().is_empty());
    p.authorize_distributor<DemoDistributor>(&cap);
    p.authorize_distributor<ReplacementDistributor>(&cap);
    assert_eq!(
        *p.distributors().keys(),
        vector[
            type_name::with_defining_ids<DemoDistributor>(),
            type_name::with_defining_ids<ReplacementDistributor>(),
        ],
    );
    p.revoke_distributor<DemoDistributor>(&cap);
    assert_eq!(
        *p.distributors().keys(),
        vector[type_name::with_defining_ids<ReplacementDistributor>()],
    );
    destroy(p);
    destroy(cap);
}
