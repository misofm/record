// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_record::record_tests;

use miso_record::record;
use miso_record::settings;
use std::type_name;
use sui::dynamic_field as df;
use sui::sui::SUI;

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
fun authorized_mint_holds_fields_and_is_extensible() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let release = id(@0xBEEF);

    let (mut cfg, cap) = settings::new_for_testing(&mut ctx);
    settings::authorize<DemoMinter>(&mut cfg, &cap);
    assert!(settings::is_authorized<DemoMinter>(&cfg));

    let mut r = record::mint<DemoMinter, SUI>(DemoMinter {}, &cfg, release, 2, 7, 100, &mut ctx);
    assert!(record::release_id(&r) == release);
    assert!(record::edition(&r) == 2);
    assert!(record::number(&r) == 7);
    assert!(record::purchase_price(&r) == 100);
    assert!(record::purchase_currency(&r) == type_name::with_defining_ids<SUI>());

    // An extension attaches state through the open uid_mut and reads it back.
    df::add(record::uid_mut(&mut r), DemoKey(), b"pressing");
    assert!(df::exists(record::uid(&r), DemoKey()));
    let _: vector<u8> = df::remove(record::uid_mut(&mut r), DemoKey());

    record::destroy(r);
    settings::destroy_for_testing(cfg, cap);
}

#[test]
fun derived_mint_is_addressable_from_parent() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let release = id(@0xBEEF);

    let (mut cfg, cap) = settings::new_for_testing(&mut ctx);
    settings::authorize<DemoMinter>(&mut cfg, &cap);

    let mut parent = object::new(&mut ctx);
    let r = record::mint_derived<DemoMinter, SUI>(DemoMinter {}, &cfg, &mut parent, release, 0, 1, 50, &ctx);
    assert!(record::edition(&r) == 0);
    assert!(record::number(&r) == 1);
    assert!(record::purchase_price(&r) == 50);
    assert!(record::is_derived_from(&r, parent.to_inner()));

    record::destroy(r);
    parent.delete();
    settings::destroy_for_testing(cfg, cap);
}

#[test]
#[expected_failure(abort_code = ENotAuthorized, location = miso_record::record)]
fun unauthorized_witness_cannot_mint() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, cap) = settings::new_for_testing(&mut ctx);

    // Impostor was never authorized — this aborts.
    let r = record::mint<Impostor, SUI>(Impostor {}, &cfg, id(@0xBEEF), 0, 1, 1, &mut ctx);

    record::destroy(r);
    settings::destroy_for_testing(cfg, cap);
}

#[test]
#[expected_failure(abort_code = ENotAuthorized, location = miso_record::record)]
fun revoked_witness_cannot_mint() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut cfg, cap) = settings::new_for_testing(&mut ctx);
    settings::authorize<DemoMinter>(&mut cfg, &cap);
    settings::revoke<DemoMinter>(&mut cfg, &cap);

    let r = record::mint<DemoMinter, SUI>(DemoMinter {}, &cfg, id(@0xBEEF), 0, 1, 1, &mut ctx);

    record::destroy(r);
    settings::destroy_for_testing(cfg, cap);
}
