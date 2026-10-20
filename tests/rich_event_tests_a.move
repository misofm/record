// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

#[test_only]
module record::rich_event_tests_a;

use musicos::release::{Self, Release, ReleaseAdminCap};
use record::pressing::{Self, Pressing};
use record::record::{Self, Record};
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario as ts;

public struct Distributor() has drop;
public struct USD() has drop;

fun ident(a: address): ID {
    object::id_from_address(a)
}

fun release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    release::new_for_testing(vector[], ctx)
}

fun press(p: &mut Pressing, price: u64): Record {
    p.press<Distributor, USD>(Distributor(), price)
}

#[test]
fun creation_event_identifies_the_new_edition() {
    let mut c = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut rel, rel_cap) = release(&mut c);
    let rel_id = object::id(&rel);
    let (p, p_cap) = pressing::new(&mut rel, &rel_cap, 1, 12);
    let mut events = event::events_by_type<pressing::PressingCreatedEvent>();
    assert_eq!(events.length(), 1);
    let (pid, rid, edition, max) = pressing::created_event_fields(&events.pop_back());
    assert_eq!(pid, object::id(&p));
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
    let (mut p, cap) = pressing::new_for_testing(ident(@0xBEEF), 2, 100, scenario.ctx());
    let p_id = object::id(&p);
    p.authorize_distributor<Distributor>(&cap);
    let r = press(&mut p, 9);
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
    ts::return_shared(p);
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
    let (mut p, cap) = pressing::new_for_testing(ident(@0xBEEF), 1, 100, &mut c);
    p.authorize_distributor<Distributor>(&cap);
    let r = press(&mut p, 3);
    let _ = p.release_id();
    let _ = p.edition();
    let _ = p.supply();
    let _ = p.max_supply();
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
