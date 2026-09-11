// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module record::rich_event_tests_b;

use record::pressing::{Self, Pressing};
use record::record::{Self, Record};
use std::type_name;
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
    let r = p.mint<Distributor, C>(Distributor(), price, &c, ctx);
    c.destroy_for_testing();
    r
}

#[test]
fun purchase_event_is_separated_by_currency_type() {
    let mut c = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, option::none(), &mut c);
    p.authorize_distributor<Distributor>(&cap);
    let mut usd = mint<USD>(&mut p, 5, 10, &mut c);
    let mut eur = mint<EUR>(&mut p, 7, 20, &mut c);
    let mut ue = event::events_by_type<pressing::RecordPurchasedEvent<Distributor, USD>>();
    let mut ee = event::events_by_type<pressing::RecordPurchasedEvent<Distributor, EUR>>();
    assert_eq!(ue.length(), 1);
    assert_eq!(ee.length(), 1);
    let (_, _, _, _, _, currency, price, buyer, time, _, before, delta, after, max) =
        pressing::purchased_event_fields(ue.pop_back());
    assert_eq!(currency, type_name::with_defining_ids<USD>().into_string());
    assert_eq!(price, 5);
    assert_eq!(buyer, @0xA);
    assert_eq!(time, 10);
    assert_eq!(before, 0);
    assert_eq!(delta, 1);
    assert_eq!(after, 1);
    assert_eq!(max, option::none());
    let (_, _, _, _, _, currency, price, _, time, _, before, delta, after, _) =
        pressing::purchased_event_fields(ee.pop_back());
    assert_eq!(currency, type_name::with_defining_ids<EUR>().into_string());
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
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, option::some(2), &mut c);
    p.authorize_distributor<Distributor>(&cap);
    let mut first = mint<USD>(&mut p, 1, 0, &mut c);
    first.destroy();
    let second = mint<USD>(&mut p, 1, 0, &mut c);
    assert_eq!(p.supply(), 2);
    assert_eq!(second.number(), 2);
    let mut events = event::events_by_type<pressing::RecordPurchasedEvent<Distributor, USD>>();
    assert_eq!(events.length(), 2);
    let (_, _, _, _, number, _, _, _, _, _, before, delta, after, max) =
        pressing::purchased_event_fields(events[1]);
    assert_eq!(number, 2);
    assert_eq!(before, 1);
    assert_eq!(delta, 1);
    assert_eq!(after, 2);
    assert_eq!(max, option::some(2));
    second.destroy();
    destroy(p);
    destroy(cap);
}

#[test]
fun destruction_event_keeps_original_purchase_provenance() {
    let mut s = ts::begin(@0xA);
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, option::none(), s.ctx());
    p.authorize_distributor<Distributor>(&cap);
    let r = mint<USD>(&mut p, 11, 99, s.ctx());
    destroy(p);
    destroy(cap);
    transfer::public_transfer(r, @0xB);
    s.next_tx(@0xB);
    let mut r = s.take_from_sender<Record>();
    r.destroy();
    let mut events = event::events_by_type<record::RecordDestroyedEvent>();
    assert_eq!(events.length(), 1);
    let (_, _, _, _, _, currency, price, buyer, time) =
        record::destroyed_event_fields(events.pop_back());
    assert_eq!(currency, type_name::with_defining_ids<USD>().into_string());
    assert_eq!(price, 11);
    assert_eq!(buyer, @0xA);
    assert_eq!(time, 99);
    s.end();
}

#[test, expected_failure(abort_code = pressing::EUnauthorized, location = pressing)]
fun foreign_cap_reauthorize_still_aborts() {
    let mut c = tx_context::dummy();
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, option::none(), &mut c);
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
    let (mut p, cap) = pressing::new_for_testing(id(@0xBEEF), 1, option::none(), &mut c);
    let foreign = pressing::foreign_admin_cap_for_testing(id(@0xDEAD), &mut c);
    p.revoke_distributor<Distributor>(&foreign);
    destroy(p);
    destroy(cap);
    destroy(foreign);
}
