// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_record::record_tests;

use miso_record::record;
use miso_record::settings;
use std::type_name;
use sui::clock;
use sui::dynamic_field as df;
use sui::event;
use sui::test_scenario;

/// Stand-in for a sale package's minter witness.
public struct DemoMinter has drop {}

/// A witness that is never authorized.
public struct Impostor has drop {}

/// Stand-in for an extension's package-private dynamic-field key.
public struct DemoKey() has copy, drop, store;

/// Mirror of `record::ENotAuthorized` (module-private constants aren't importable).
const ENotAuthorized: u64 = 0;

fun id(addr: address): ID {
    object::id_from_address(addr)
}

#[test]
fun authorized_mint_derives_off_the_parent_and_is_extensible() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let release = id(@0xBEEF);
    let clk = clock_at(1_700_000_000_000, &mut ctx);

    let (mut cfg, cap) = settings::new_for_testing(&mut ctx);
    settings::authorize<DemoMinter>(&mut cfg, &cap, &ctx);
    assert!(settings::is_authorized<DemoMinter>(&cfg));

    let mut parent = object::new(&mut ctx);
    let parent_id = parent.to_inner();
    let mut r = record::mint<DemoMinter>(DemoMinter {}, &cfg, &mut parent, release, 7, &clk, &ctx);
    assert!(record::release_id(&r) == release);
    // The birth date comes off the clock, never from the minter.
    assert!(record::created_at_ms(&r) == 1_700_000_000_000);

    // Every record derives off its minting parent: the address is pure math over the
    // parent and the claim slot, so provenance is verifiable by recomputing it. The
    // record does not store the slot — the issuer's serial field names it.
    assert!(record::id(&r) == record::derive_id(parent.to_inner(), 7));
    assert!(record::id(&r) != record::derive_id(release, 7));

    let mut created_events = event::events_by_type<record::RecordCreatedEvent>();
    assert!(created_events.length() == 1);
    let (record_id, event_parent_id, event_release_id, number, created_at_ms, minter, created_by) =
        record::record_created_event_fields(created_events.pop_back());
    assert!(record_id == record::id(&r));
    assert!(event_parent_id == parent_id);
    assert!(event_release_id == release);
    assert!(number == 7);
    assert!(created_at_ms == 1_700_000_000_000);
    assert!(minter == type_name::with_defining_ids<DemoMinter>());
    assert!(created_by == @0xA);

    // An extension attaches state through the open uid_mut and reads it back.
    df::add(record::uid_mut(&mut r), DemoKey(), b"pressing");
    assert!(df::exists(record::uid(&r), DemoKey()));
    let _: vector<u8> = df::remove(record::uid_mut(&mut r), DemoKey());

    let destroyed_record_id = record::id(&r);
    record::destroy(r, &ctx);
    let mut destroyed_events = event::events_by_type<record::RecordDestroyedEvent>();
    assert!(destroyed_events.length() == 1);
    let (record_id, event_release_id, destroyed_by) =
        record::record_destroyed_event_fields(destroyed_events.pop_back());
    assert!(record_id == destroyed_record_id);
    assert!(event_release_id == release);
    assert!(destroyed_by == @0xA);
    parent.delete();
    settings::destroy_for_testing(cfg, cap);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure] // derived_object::claim aborts: RecordKey(number) is claim-once
fun a_serial_can_be_minted_at_most_once_per_parent() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut cfg, cap) = settings::new_for_testing(&mut ctx);
    settings::authorize<DemoMinter>(&mut cfg, &cap, &ctx);

    let mut parent = object::new(&mut ctx);
    let r1 = record::mint<DemoMinter>(DemoMinter {}, &cfg, &mut parent, id(@0xBEEF), 1, &clk, &ctx);
    let r2 = record::mint<DemoMinter>(DemoMinter {}, &cfg, &mut parent, id(@0xBEEF), 1, &clk, &ctx);

    record::destroy(r1, &ctx);
    record::destroy(r2, &ctx);
    parent.delete();
    settings::destroy_for_testing(cfg, cap);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = ENotAuthorized, location = miso_record::record)]
fun unauthorized_witness_cannot_mint() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let (cfg, cap) = settings::new_for_testing(&mut ctx);

    // Impostor was never authorized — this aborts.
    let mut parent = object::new(&mut ctx);
    let r = record::mint<Impostor>(Impostor {}, &cfg, &mut parent, id(@0xBEEF), 1, &clk, &ctx);

    record::destroy(r, &ctx);
    parent.delete();
    settings::destroy_for_testing(cfg, cap);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = ENotAuthorized, location = miso_record::record)]
fun revoked_witness_cannot_mint() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut cfg, cap) = settings::new_for_testing(&mut ctx);
    settings::authorize<DemoMinter>(&mut cfg, &cap, &ctx);
    settings::revoke<DemoMinter>(&mut cfg, &cap, &ctx);

    let mut parent = object::new(&mut ctx);
    let r = record::mint<DemoMinter>(DemoMinter {}, &cfg, &mut parent, id(@0xBEEF), 1, &clk, &ctx);

    record::destroy(r, &ctx);
    parent.delete();
    settings::destroy_for_testing(cfg, cap);
    clk.destroy_for_testing();
}

fun clock_at(ms: u64, ctx: &mut TxContext): clock::Clock {
    let mut c = clock::create_for_testing(ctx);
    c.set_for_testing(ms);
    c
}

#[test]
fun settings_events_are_complete() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut cfg, cap) = settings::new_for_testing(&mut ctx);
    let settings_id = object::id(&cfg);
    let admin_cap_id = object::id(&cap);

    let mut created_events = event::events_by_type<settings::SettingsCreatedEvent>();
    assert!(created_events.length() == 1);
    let (event_settings_id, event_admin_cap_id, admin) =
        settings::settings_created_event_fields(created_events.pop_back());
    assert!(event_settings_id == settings_id);
    assert!(event_admin_cap_id == admin_cap_id);
    assert!(admin == @0xA);

    settings::authorize<DemoMinter>(&mut cfg, &cap, &ctx);
    let mut authorized_events = event::events_by_type<settings::MinterAuthorizedEvent>();
    assert!(authorized_events.length() == 1);
    let (event_settings_id, event_admin_cap_id, minter, authorized_by) =
        settings::minter_authorized_event_fields(authorized_events.pop_back());
    assert!(event_settings_id == settings_id);
    assert!(event_admin_cap_id == admin_cap_id);
    assert!(minter == type_name::with_defining_ids<DemoMinter>());
    assert!(authorized_by == @0xA);

    settings::revoke<DemoMinter>(&mut cfg, &cap, &ctx);
    let mut revoked_events = event::events_by_type<settings::MinterRevokedEvent>();
    assert!(revoked_events.length() == 1);
    let (event_settings_id, event_admin_cap_id, minter, revoked_by) =
        settings::minter_revoked_event_fields(revoked_events.pop_back());
    assert!(event_settings_id == settings_id);
    assert!(event_admin_cap_id == admin_cap_id);
    assert!(minter == type_name::with_defining_ids<DemoMinter>());
    assert!(revoked_by == @0xA);

    settings::destroy_for_testing(cfg, cap);
}

#[test]
fun init_shares_settings_and_transfers_the_admin_cap() {
    let mut scenario = test_scenario::begin(@0xA);
    settings::init_for_testing(scenario.ctx());

    scenario.next_tx(@0xA);
    let cfg = scenario.take_shared<settings::Settings>();
    let cap = scenario.take_from_sender<settings::SettingsAdminCap>();
    assert!(settings::minters(&cfg).is_empty());

    test_scenario::return_shared(cfg);
    scenario.return_to_sender(cap);
    scenario.end();
}
