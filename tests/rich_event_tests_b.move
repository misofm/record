// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module record::rich_event_tests_b;

use record::pressing::{Self, Pressing};
use record::record::{Self, Record};
use std::unit_test::{assert_eq, destroy};
use sui::clock;
use sui::event;
use sui::test_scenario as ts;

public struct Distributor() has drop;
public struct USD() has drop;
public struct EUR() has drop;

fun id(a: address): ID {
    object::id_from_address(a)
}

fun mint<C>(
    p: &mut Pressing,
    price: u64,
    time: u64,
    ctx: &mut TxContext,
): Record {
    let mut c = clock::create_for_testing(ctx);
    c.set_for_testing(time);
    let r = p.mint<Distributor, C>(Distributor(), price, &c);
    c.destroy_for_testing();
    r
}

#[test]
fun purchase_event_is_separated_by_currency_type() {
    let mut c = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut c);
    p.authorize_distributor<Distributor>(&cap);
    let usd = mint<USD>(&mut p, 5, 10, &mut c);
    let eur = mint<EUR>(&mut p, 7, 20, &mut c);
    let mut ue = event::events_by_type<pressing::RecordPurchasedEvent<Distributor, USD>>();
    let mut ee = event::events_by_type<pressing::RecordPurchasedEvent<Distributor, EUR>>();
    assert_eq!(ue.length(), 1);
    assert_eq!(ee.length(), 1);
    let (_, _, _, _, _, price, time, before, delta, after, max) =
        pressing::purchased_event_fields(ue.pop_back());
    assert_eq!(price, 5);
    assert_eq!(time, 10);
    assert_eq!(before, 0);
    assert_eq!(delta, 1);
    assert_eq!(after, 1);
    assert_eq!(max, 100);
    let (_, _, _, _, _, price, time, before, delta, after, _) =
        pressing::purchased_event_fields(ee.pop_back());
    assert_eq!(price, 7);
    assert_eq!(time, 20);
    assert_eq!(before, 1);
    assert_eq!(delta, 1);
    assert_eq!(after, 2);
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
    let first = mint<USD>(&mut p, 1, 0, &mut c);
    first.destroy();
    let second = mint<USD>(&mut p, 1, 0, &mut c);
    assert_eq!(p.supply(), 2);
    assert_eq!(second.number(), 2);
    let events = event::events_by_type<pressing::RecordPurchasedEvent<Distributor, USD>>();
    assert_eq!(events.length(), 2);
    let (_, _, _, _, number, _, _, before, delta, after, max) =
        pressing::purchased_event_fields(events[1]);
    assert_eq!(number, 2);
    assert_eq!(before, 1);
    assert_eq!(delta, 1);
    assert_eq!(after, 2);
    assert_eq!(max, 2);
    second.destroy();
    destroy(p);
    destroy(cap);
}

#[test]
fun destruction_event_identifies_only_destroyed_record() {
    let mut s = ts::begin(@0xA);
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 100, s.ctx());
    p.authorize_distributor<Distributor>(&cap);
    let r = mint<USD>(&mut p, 11, 99, s.ctx());
    destroy(p);
    destroy(cap);
    transfer::public_transfer(r, @0xB);
    s.next_tx(@0xB);
    let r = s.take_from_sender<Record>();
    r.destroy();
    let mut events = event::events_by_type<record::RecordDestroyedEvent>();
    assert_eq!(events.length(), 1);
    let event = events.pop_back();
    assert_eq!(std::bcs::to_bytes(&event).length(), 102);
    let (record_id, release_id, pressing_id, edition, number) =
        record::destroyed_event_fields(event);
    assert!(record_id != @0x0);
    assert_eq!(release_id, @0xBEEF);
    assert!(pressing_id != @0x0);
    assert_eq!(edition, 1);
    assert_eq!(number, 1);
    s.end();
}

#[test, expected_failure(abort_code = pressing::EUnauthorized, location = pressing)]
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

#[test, expected_failure(abort_code = pressing::EUnauthorized, location = pressing)]
fun foreign_cap_missing_revoke_still_aborts() {
    let mut c = tx_context::dummy();
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, 100, &mut c);
    let foreign = pressing::foreign_admin_cap_for_testing(id(@0xDEAD), &mut c);
    p.revoke_distributor<Distributor>(&foreign);
    destroy(p);
    destroy(cap);
    destroy(foreign);
}
