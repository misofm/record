// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_record::record_tests;

use miso_record::record;
use miso_record::settings;
use sui::clock;
use sui::dynamic_field as df;

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
    settings::authorize<DemoMinter>(&mut cfg, &cap);
    assert!(settings::is_authorized<DemoMinter>(&cfg));

    let mut parent = object::new(&mut ctx);
    let mut r = record::mint<DemoMinter>(DemoMinter {}, &cfg, &mut parent, release, 7, &clk, &ctx);
    assert!(record::release_id(&r) == release);
    // The birth date comes off the clock, never from the minter.
    assert!(record::created_at_ms(&r) == 1_700_000_000_000);

    // Every record derives off its minting parent: the address is pure math over the
    // parent and the claim slot, so provenance is verifiable by recomputing it. The
    // record does not store the slot — the issuer's serial field names it.
    assert!(record::id(&r) == record::derive_id(parent.to_inner(), 7));
    assert!(record::id(&r) != record::derive_id(release, 7));

    // An extension attaches state through the open uid_mut and reads it back.
    df::add(record::uid_mut(&mut r), DemoKey(), b"pressing");
    assert!(df::exists(record::uid(&r), DemoKey()));
    let _: vector<u8> = df::remove(record::uid_mut(&mut r), DemoKey());

    record::destroy(r);
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
    settings::authorize<DemoMinter>(&mut cfg, &cap);

    let mut parent = object::new(&mut ctx);
    let r1 = record::mint<DemoMinter>(DemoMinter {}, &cfg, &mut parent, id(@0xBEEF), 1, &clk, &ctx);
    let r2 = record::mint<DemoMinter>(DemoMinter {}, &cfg, &mut parent, id(@0xBEEF), 1, &clk, &ctx);

    record::destroy(r1);
    record::destroy(r2);
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

    record::destroy(r);
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
    settings::authorize<DemoMinter>(&mut cfg, &cap);
    settings::revoke<DemoMinter>(&mut cfg, &cap);

    let mut parent = object::new(&mut ctx);
    let r = record::mint<DemoMinter>(DemoMinter {}, &cfg, &mut parent, id(@0xBEEF), 1, &clk, &ctx);

    record::destroy(r);
    parent.delete();
    settings::destroy_for_testing(cfg, cap);
    clk.destroy_for_testing();
}

fun clock_at(ms: u64, ctx: &mut TxContext): clock::Clock {
    let mut c = clock::create_for_testing(ctx);
    c.set_for_testing(ms);
    c
}
