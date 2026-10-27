// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

#[test_only]
module record::pressing_event_tests;

use std::{bcs, type_name, unit_test::{assert_eq, destroy}};
use sui::{clock, event, test_scenario as ts};
use miso_music::release::{Self, Release, ReleaseAdminCap};
use record::{pressing::{Self, Pressing}, record::{Self, Record}};

const PURCHASED_AT_MS: u64 = 1_726_000_123;

public struct Distributor() has drop;

public struct USD() has drop;

public struct EUR() has drop;

fun id(a: address): ID {
    object::id_from_address(a)
}

fun release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    release::new_for_testing(vector[], ctx)
}

fun press<Currency>(p: &mut Pressing, price: u64): Record {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(PURCHASED_AT_MS);
    let record = p.press<Distributor, Currency>(Distributor(), price, &clock);
    clock.destroy_for_testing();
    record
}

#[test]
fun creation_event_identifies_the_new_edition() {
    let mut c = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut rel, rel_cap) = release(&mut c);
    let rel_id = object::id(&rel);
    let (p, p_cap) = pressing::new(&mut rel, &rel_cap, 1, 12);
    let mut events = event::events_by_type<pressing::PressingCreatedEvent>();
    assert_eq!(events.length(), 1);
    let (pid, cap_id, rid, edition, max) = pressing::created_event_fields(&events.pop_back());
    assert_eq!(pid, object::id(&p));
    assert_eq!(cap_id, object::id(&p_cap));
    assert_eq!(rid, rel_id);
    assert_eq!(edition, 1);
    assert_eq!(max, 12);
    assert_eq!(object::id_address(&p_cap), pressing::derive_admin_cap_address(pid));
    assert_eq!(p.supply(), 0);
    destroy(p);
    destroy(p_cap);
    destroy(rel);
    destroy(rel_cap);
}

#[test]
fun sharing_is_silent_and_preserves_config_and_supply() {
    let mut scenario = ts::begin(@0xA);
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 2, 100, scenario.ctx());
    let p_id = object::id(&p);
    p.authorize_distributor<Distributor>(&cap);
    let r = press<USD>(&mut p, 9);
    r.destroy();
    let event_count = event::num_events();
    p.share();
    assert_eq!(event::num_events(), event_count);
    destroy(cap);

    scenario.next_tx(@0xB);
    let p = scenario.take_shared<Pressing>();
    assert_eq!(object::id(&p), p_id);
    assert_eq!(p.release_id(), id(@0xBEEF));
    assert_eq!(p.edition(), 2);
    assert_eq!(p.supply(), 1);
    assert_eq!(p.max_supply(), 100);
    assert!(p.is_distributor_authorized<Distributor>());
    ts::return_shared(p);
    scenario.end();
}

#[test]
fun distributor_events_capture_only_real_set_changes() {
    let mut c = tx_context::dummy();
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut c);
    p.authorize_distributor<Distributor>(&cap);
    p.authorize_distributor<Distributor>(&cap);
    p.revoke_distributor<Distributor>(&cap);
    p.revoke_distributor<Distributor>(&cap);

    let a = event::events_by_type<pressing::PressingDistributorAuthorizedEvent<Distributor>>();
    let r = event::events_by_type<pressing::PressingDistributorRevokedEvent<Distributor>>();
    assert_eq!(a.length(), 1);
    assert_eq!(r.length(), 1);
    assert_eq!(pressing::authorized_event_pressing_id(&a[0]), object::id(&p));
    assert_eq!(pressing::revoked_event_pressing_id(&r[0]), object::id(&p));
    destroy(p);
    destroy(cap);
}

#[test]
fun view_and_uid_borrows_are_event_silent() {
    let mut c = tx_context::dummy();
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut c);
    p.authorize_distributor<Distributor>(&cap);
    let r = press<USD>(&mut p, 3);
    let _ = p.release_id();
    let _ = p.edition();
    let _ = p.supply();
    let _ = p.max_supply();
    let _ = p.distributors();
    let _ = p.uid();
    let _ = r.release_id();
    let _ = r.pressing_id();
    let _ = r.edition();
    let _ = r.number();
    let _ = r.purchase_currency();
    let _ = r.purchase_price();
    let _ = r.uid();
    let purchased = event::events_by_type<pressing::RecordPurchasedEvent<Distributor, USD>>();
    assert_eq!(purchased.length(), 1);
    r.destroy();
    destroy(p);
    destroy(cap);
}

#[test]
fun purchase_event_is_separated_by_currency_type() {
    let mut c = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut c);
    p.authorize_distributor<Distributor>(&cap);
    let usd = press<USD>(&mut p, 5);
    let eur = press<EUR>(&mut p, 7);
    assert_eq!(usd.purchase_currency(), type_name::with_defining_ids<USD>());
    assert_eq!(eur.purchase_currency(), type_name::with_defining_ids<EUR>());
    let mut ue = event::events_by_type<pressing::RecordPurchasedEvent<Distributor, USD>>();
    let mut ee = event::events_by_type<pressing::RecordPurchasedEvent<Distributor, EUR>>();
    assert_eq!(ue.length(), 1);
    assert_eq!(ee.length(), 1);
    let (_, _, number, price, purchased_at_ms) = pressing::purchased_event_fields(&ue.pop_back());
    assert_eq!(number, 1);
    assert_eq!(price, 5);
    assert_eq!(purchased_at_ms, PURCHASED_AT_MS);
    let (_, _, number, price, purchased_at_ms) = pressing::purchased_event_fields(&ee.pop_back());
    assert_eq!(number, 2);
    assert_eq!(price, 7);
    assert_eq!(purchased_at_ms, PURCHASED_AT_MS);
    usd.destroy();
    eur.destroy();
    destroy(p);
    destroy(cap);
}

#[test]
fun capped_supply_is_lifetime_supply_after_destruction() {
    let mut c = tx_context::dummy();
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 2, &mut c);
    p.authorize_distributor<Distributor>(&cap);
    let first = press<USD>(&mut p, 1);
    first.destroy();
    let second = press<USD>(&mut p, 1);
    assert_eq!(p.supply(), 2);
    assert_eq!(second.number(), 2);
    let events = event::events_by_type<pressing::RecordPurchasedEvent<Distributor, USD>>();
    assert_eq!(events.length(), 2);
    let (_, _, number, _, _) = pressing::purchased_event_fields(&events[1]);
    assert_eq!(number, 2);
    second.destroy();
    destroy(p);
    destroy(cap);
}

#[test]
fun destruction_event_identifies_only_destroyed_record() {
    let mut s = ts::begin(@0xA);
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 100, s.ctx());
    p.authorize_distributor<Distributor>(&cap);
    let r = press<USD>(&mut p, 11);
    destroy(p);
    destroy(cap);
    transfer::public_transfer(r, @0xB);
    s.next_tx(@0xB);
    let r = s.take_from_sender<Record>();
    let record_id = object::id(&r);
    r.destroy();
    let events = event::events_by_type<record::RecordDestroyedEvent>();
    assert_eq!(events.length(), 1);
    assert_eq!(bcs::to_bytes(&events[0]).length(), 32);
    assert_eq!(record::destroyed_event_record_id(&events[0]), record_id);
    s.end();
}

#[test, expected_failure(abort_code = pressing::EUnauthorized)]
fun foreign_cap_reauthorize_still_aborts() {
    let mut c = tx_context::dummy();
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut c);
    p.authorize_distributor<Distributor>(&cap);
    let foreign = pressing::foreign_admin_cap_for_testing(id(@0xDEAD), &mut c);
    p.authorize_distributor<Distributor>(&foreign);
    destroy(p);
    destroy(cap);
    destroy(foreign);
}

#[test, expected_failure(abort_code = pressing::EUnauthorized)]
fun foreign_cap_missing_revoke_still_aborts() {
    let mut c = tx_context::dummy();
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut c);
    let foreign = pressing::foreign_admin_cap_for_testing(id(@0xDEAD), &mut c);
    p.revoke_distributor<Distributor>(&foreign);
    destroy(p);
    destroy(cap);
    destroy(foreign);
}
