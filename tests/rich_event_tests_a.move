// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module record::rich_event_tests_a;

use musicos::release::{Self, Release, ReleaseAdminCap};
use record::pressing::{Self, Pressing};
use record::record::{Self, Record};
use std::unit_test::{assert_eq, destroy};
use sui::clock;
use sui::event;

public struct Distributor() has drop;
public struct USD() has drop;

fun ident(a: address): ID {
    object::id_from_address(a)
}

fun release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    release::new_for_testing("Test", vector[], ctx)
}

fun mint(
    p: &mut Pressing,
    price: u64,
    time: u64,
    ctx: &mut TxContext,
): Record {
    let mut c = clock::create_for_testing(ctx);
    c.set_for_testing(time);
    let r = p.mint<Distributor, USD>(Distributor(), price, &c, ctx);
    c.destroy_for_testing();
    r
}

#[test]
fun creation_event_is_a_complete_snapshot() {
    let mut c = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut rel, rel_cap) = release(&mut c);
    let rel_id = object::id(&rel);
    let (p, p_cap) = pressing::new(&mut rel, &rel_cap, 1, 12);
    let mut events = event::events_by_type<pressing::PressingCreatedEvent>();
    assert_eq!(events.length(), 1);
    let (pid, rid, pcap, rcap, edition, supply, max, distributors) =
        pressing::created_event_fields(events.pop_back());
    assert_eq!(pid, object::id(&p).to_address());
    assert_eq!(rid, rel_id.to_address());
    assert_eq!(pcap, object::id(&p_cap).to_address());
    assert_eq!(rcap, object::id(&rel_cap).to_address());
    assert_eq!(edition, 1);
    assert_eq!(supply, 0);
    assert_eq!(max, 12);
    assert_eq!(distributors, vector[]);
    destroy(p);
    destroy(p_cap);
    destroy(rel);
    destroy(rel_cap);
}

#[test]
fun sharing_is_silent_and_preserves_config_and_supply() {
    let mut scenario = sui::test_scenario::begin(@0xA);
    let (mut p, cap) = pressing::new_for_testing(ident(@0xBEEF), 2, 100, scenario.ctx());
    let p_id = object::id(&p);
    p.authorize_distributor<Distributor>(&cap);
    let r = mint(&mut p, 9, 42, scenario.ctx());
    r.destroy();
    let event_count = event::num_events();
    p.share();
    assert_eq!(event::num_events(), event_count);
    destroy(cap);

    scenario.next_tx(@0xB);
    let p = scenario.take_shared<Pressing>();
    assert_eq!(object::id(&p), p_id);
    assert_eq!(p.release_id(), ident(@0xBEEF));
    assert_eq!(p.edition(), 2);
    assert_eq!(p.supply(), 1);
    assert_eq!(p.max_supply(), 100);
    assert!(p.is_distributor_authorized<Distributor>());
    assert_eq!(p.distributors().length(), 1);
    sui::test_scenario::return_shared(p);
    scenario.end();
}

#[test]
fun distributor_events_capture_only_real_set_changes() {
    let mut c = tx_context::dummy();
    let (mut p, cap) = pressing::new_for_testing(ident(@0xBEEF), 1, 100, &mut c);
    p.authorize_distributor<Distributor>(&cap);
    p.authorize_distributor<Distributor>(&cap);
    p.revoke_distributor<Distributor>(&cap);
    p.revoke_distributor<Distributor>(&cap);

    let mut a = event::events_by_type<pressing::PressingDistributorAuthorizedEvent<Distributor>>();
    let mut r = event::events_by_type<pressing::PressingDistributorRevokedEvent<Distributor>>();
    assert_eq!(a.length(), 1);
    assert_eq!(r.length(), 1);
    let (pid, rid, edition, cap_id, before, after, count_before, count_after) =
        pressing::authorized_event_fields(a.pop_back());
    assert_eq!(pid, object::id(&p).to_address());
    assert_eq!(rid, @0xBEEF);
    assert_eq!(edition, 1);
    assert_eq!(cap_id, object::id(&cap).to_address());
    assert!(!before);
    assert!(after);
    assert_eq!(count_before, 0);
    assert_eq!(count_after, 1);
    let (_, _, _, _, before, after, count_before, count_after) =
        pressing::revoked_event_fields(r.pop_back());
    assert!(before);
    assert!(!after);
    assert_eq!(count_before, 1);
    assert_eq!(count_after, 0);
    destroy(p);
    destroy(cap);
}

#[test]
fun view_and_uid_borrows_are_event_silent() {
    let mut c = tx_context::dummy();
    let (mut p, cap) = pressing::new_for_testing(ident(@0xBEEF), 1, 100, &mut c);
    p.authorize_distributor<Distributor>(&cap);
    let r = mint(&mut p, 3, 0, &mut c);
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
    let _ = r.purchased_by();
    let _ = r.purchased_timestamp_ms();
    let _ = r.uid();
    assert_eq!(event::events_by_type<pressing::RecordPurchasedEvent<Distributor, USD>>().length(), 1);
    r.destroy();
    destroy(p);
    destroy(cap);
}
