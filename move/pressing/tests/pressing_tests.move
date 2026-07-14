// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_pressing::pressing_tests;

use miso::release::{Self, Release, ReleaseAdminCap};
use miso_pressing::pressing::{Self, MintWitness};
use miso_record::record;
use miso_record::settings;
use std::type_name;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::sui::SUI;

/// Mirrors of the module-private abort codes (constants aren't importable).
const ENotAuthorized: u64 = 0; // miso_record::record
const EInsufficientPayment: u64 = 1; // miso_pressing::pressing
const EPressingNotStarted: u64 = 2;
const EPressingClosed: u64 = 3;
const EInvalidWindow: u64 = 4;
const ENonSequentialEdition: u64 = 5;
const EBpsOverflow: u64 = 0; // bps::bps (rate above 100%)

fun id(addr: address): ID {
    object::id_from_address(addr)
}

/// A `Settings` with this pressing's `MintWitness` authorized.
fun authorized_settings(ctx: &mut TxContext): (settings::Settings, settings::SettingsAdminCap) {
    let (mut cfg, admin) = settings::new_for_testing(ctx);
    settings::authorize<MintWitness>(&mut cfg, &admin);
    (cfg, admin)
}

fun clock_at(ms: u64, ctx: &mut TxContext): Clock {
    let mut c = clock::create_for_testing(ctx);
    c.set_for_testing(ms);
    c
}

fun a_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    release::new_for_testing(b"Test".to_string(), vector[], ctx)
}

//=== press ===

#[test]
fun press_mints_sequential_records_derived_off_the_pressing() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let release = id(@0xBEEF);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx); // t = 0

    // Edition 3, opens at 0, no close, free, no referral program.
    let mut p = pressing::new_for_testing<SUI>(
        release, 3, pressing::new_fixed_price(0), option::none(), 0, option::none(), &mut ctx,
    );

    let r1 = pressing::press(&mut p, coin::zero<SUI>(&mut ctx), option::none(), &cfg, &clk, &mut ctx);
    let r2 = pressing::press(&mut p, coin::zero<SUI>(&mut ctx), option::none(), &cfg, &clk, &mut ctx);

    // 1-based, sequential; stamped with release, edition, and purchase terms.
    assert!(record::number(&r1) == 1);
    assert!(record::number(&r2) == 2);
    assert!(record::edition(&r1) == 3);
    assert!(record::release_id(&r1) == release);
    assert!(record::purchase_price(&r1) == 0);
    assert!(record::purchase_currency(&r1) == type_name::with_defining_ids<SUI>());
    assert!(pressing::quantity_sold(&p) == 2);
    assert!(pressing::is_live(&p, &clk));

    // Each record's UID is verifiably derived off this pressing, not off some other object.
    assert!(record::is_derived_from(&r1, pressing::id(&p)));
    assert!(!record::is_derived_from(&r1, id(@0xF00D)));

    record::destroy(r1);
    record::destroy(r2);
    pressing::destroy_for_testing(p);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
fun press_records_amount_paid() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // Floor of 5; buyer pays 8 (a 3-over tip). purchase_price records the full 8.
    let mut p = pressing::new_for_testing<SUI>(
        id(@0xBEEF), 0, pressing::new_floor_price(5), option::none(), 0, option::none(), &mut ctx,
    );
    let payment = coin::mint_for_testing<SUI>(8, &mut ctx);
    let r = pressing::press(&mut p, payment, option::none(), &cfg, &clk, &mut ctx);

    assert!(record::purchase_price(&r) == 8);

    record::destroy(r);
    pressing::destroy_for_testing(p);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
fun press_with_referral_pays_commission_and_mints() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // Fixed price 100 with a 5% referral commission.
    let mut p = pressing::new_for_testing<SUI>(
        id(@0xBEEF), 0, pressing::new_fixed_price(100), option::some(bps::bps::new(500)), 0, option::none(), &mut ctx,
    );
    assert!(pressing::referral_commission_rate(&p) == option::some(500));

    // Buyer names a referrer: 5 (5% of 100) is split to @0xFEE out of proceeds, the
    // remaining 95 is forwarded to the release. The buyer still receives their record
    // at the full purchase price.
    let payment = coin::mint_for_testing<SUI>(100, &mut ctx);
    let r = pressing::press(&mut p, payment, option::some(@0xFEE), &cfg, &clk, &mut ctx);

    assert!(record::purchase_price(&r) == 100);
    assert!(record::number(&r) == 1);
    assert!(pressing::quantity_sold(&p) == 1);

    record::destroy(r);
    pressing::destroy_for_testing(p);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
fun press_with_rate_but_no_referrer_forwards_everything() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // A referral rate is set, but a direct sale (no referrer) pays no commission.
    let mut p = pressing::new_for_testing<SUI>(
        id(@0xBEEF), 0, pressing::new_fixed_price(100), option::some(bps::bps::new(500)), 0, option::none(), &mut ctx,
    );
    let payment = coin::mint_for_testing<SUI>(100, &mut ctx);
    let r = pressing::press(&mut p, payment, option::none(), &cfg, &clk, &mut ctx);

    assert!(record::purchase_price(&r) == 100);

    record::destroy(r);
    pressing::destroy_for_testing(p);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
fun is_live_reflects_window() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    // Window [100, 200].
    let p = pressing::new_for_testing<SUI>(
        id(@0xBEEF), 0, pressing::new_fixed_price(0), option::none(), 100, option::some(200), &mut ctx,
    );
    let mut clk = clock::create_for_testing(&mut ctx);

    // The test clock only moves forward, so assert in ascending order.
    clk.set_for_testing(50);
    assert!(!pressing::is_live(&p, &clk)); // before open
    clk.set_for_testing(150);
    assert!(pressing::is_live(&p, &clk)); // inside
    clk.set_for_testing(250);
    assert!(!pressing::is_live(&p, &clk)); // after close

    pressing::destroy_for_testing(p);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = ENotAuthorized, location = miso_record::record)]
fun press_aborts_when_witness_not_authorized() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = settings::new_for_testing(&mut ctx); // never authorized MintWitness
    let clk = clock::create_for_testing(&mut ctx);

    let mut p = pressing::new_for_testing<SUI>(
        id(@0xBEEF), 0, pressing::new_fixed_price(0), option::none(), 0, option::none(), &mut ctx,
    );
    let r = pressing::press(&mut p, coin::zero<SUI>(&mut ctx), option::none(), &cfg, &clk, &mut ctx);

    record::destroy(r);
    pressing::destroy_for_testing(p);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EInsufficientPayment, location = miso_pressing::pressing)]
fun press_aborts_on_underpayment() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    let mut p = pressing::new_for_testing<SUI>(
        id(@0xBEEF), 0, pressing::new_fixed_price(100), option::none(), 0, option::none(), &mut ctx,
    );
    // Pay 0 against a fixed price of 100 — aborts before any funds move.
    let r = pressing::press(&mut p, coin::zero<SUI>(&mut ctx), option::none(), &cfg, &clk, &mut ctx);

    record::destroy(r);
    pressing::destroy_for_testing(p);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EPressingNotStarted, location = miso_pressing::pressing)]
fun press_aborts_before_open() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock_at(0, &mut ctx);

    // Opens at 100; clock is at 0.
    let mut p = pressing::new_for_testing<SUI>(
        id(@0xBEEF), 0, pressing::new_fixed_price(0), option::none(), 100, option::none(), &mut ctx,
    );
    let r = pressing::press(&mut p, coin::zero<SUI>(&mut ctx), option::none(), &cfg, &clk, &mut ctx);

    record::destroy(r);
    pressing::destroy_for_testing(p);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EPressingClosed, location = miso_pressing::pressing)]
fun press_aborts_after_close() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock_at(200, &mut ctx);

    // Closes at 100; clock is at 200.
    let mut p = pressing::new_for_testing<SUI>(
        id(@0xBEEF), 0, pressing::new_fixed_price(0), option::none(), 0, option::some(100), &mut ctx,
    );
    let r = pressing::press(&mut p, coin::zero<SUI>(&mut ctx), option::none(), &cfg, &clk, &mut ctx);

    record::destroy(r);
    pressing::destroy_for_testing(p);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

//=== new: editions, window & referral rate ===

#[test]
fun editions_created_in_sequence() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let mut registry = pressing::new_registry_for_testing(&mut ctx);
    let (rel, cap) = a_release(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // Edition 0 (first pressing) needs no predecessor; edition 1 then succeeds.
    pressing::new<SUI>(
        &mut registry, &rel, &cap, pressing::new_fixed_price(0), option::none(), 0, 0, option::none(), &clk,
    );
    pressing::new<SUI>(
        &mut registry, &rel, &cap, pressing::new_fixed_price(0), option::none(), 1, 0, option::none(), &clk,
    );

    pressing::destroy_registry_for_testing(registry);
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = ENonSequentialEdition, location = miso_pressing::pressing)]
fun nonsequential_edition_aborts() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let mut registry = pressing::new_registry_for_testing(&mut ctx);
    let (rel, cap) = a_release(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // Edition 1 on a fresh registry — edition 0 doesn't exist yet.
    pressing::new<SUI>(
        &mut registry, &rel, &cap, pressing::new_fixed_price(0), option::none(), 1, 0, option::none(), &clk,
    );

    pressing::destroy_registry_for_testing(registry);
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure] // derived_object::claim aborts on a duplicate PressingKey
fun duplicate_edition_aborts() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let mut registry = pressing::new_registry_for_testing(&mut ctx);
    let (rel, cap) = a_release(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    pressing::new<SUI>(
        &mut registry, &rel, &cap, pressing::new_fixed_price(0), option::none(), 0, 0, option::none(), &clk,
    );
    // Edition 0 again for the same release — claim collision.
    pressing::new<SUI>(
        &mut registry, &rel, &cap, pressing::new_fixed_price(0), option::none(), 0, 0, option::none(), &clk,
    );

    pressing::destroy_registry_for_testing(registry);
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EInvalidWindow, location = miso_pressing::pressing)]
fun invalid_window_aborts() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let mut registry = pressing::new_registry_for_testing(&mut ctx);
    let (rel, cap) = a_release(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // Close (50) is not after open (100) — empty window.
    pressing::new<SUI>(
        &mut registry, &rel, &cap, pressing::new_fixed_price(0), option::none(), 0, 100, option::some(50), &clk,
    );

    pressing::destroy_registry_for_testing(registry);
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EBpsOverflow, location = bps::bps)]
fun referral_rate_above_100pct_aborts() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let mut registry = pressing::new_registry_for_testing(&mut ctx);
    let (rel, cap) = a_release(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // 10_001 bps > 100% — `bps::new` rejects it.
    pressing::new<SUI>(
        &mut registry, &rel, &cap, pressing::new_fixed_price(0), option::some(10001), 0, 0, option::none(), &clk,
    );

    pressing::destroy_registry_for_testing(registry);
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    clk.destroy_for_testing();
}
