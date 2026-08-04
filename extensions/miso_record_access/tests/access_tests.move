// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_record_access::access_tests;

use miso::composition::{Self, Composition};
use miso::recording::{Self, Recording};
use miso::release::{Self, Release, ReleaseAdminCap};
use miso::track;
use miso_record::record::{Self, Record};
use miso_record::settings;
use miso_record_access::access;
use std::unit_test::destroy;
use sui::clock::{Self, Clock};

/// Stand-in for a sale package's minter witness.
public struct DemoMinter has drop {}

/// Stand-in share types. They are only ever phantom parameters, so they need no
/// abilities and are never instantiated. `SONG` is the composition's durable
/// identity; `MASTER` is the recording's.
public struct SONG {}
public struct MASTER {}

fun id(addr: address): ID {
    object::id_from_address(addr)
}

/// A release holding one track per id in `recording_ids`, in order. Splits are
/// irrelevant to access, so every track takes an equal nominal share.
fun test_release(recording_ids: vector<ID>, ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let tracks = recording_ids.map!(|rid| track::new_for_testing(rid, id(@0x0), 10_000));
    release::new_for_testing(b"Test Release".to_string(), tracks, ctx)
}

/// A record of `release_id`, minted through the authorized path.
fun test_record(release_id: ID, clk: &Clock, ctx: &mut TxContext): Record {
    let (mut cfg, cap) = settings::new_for_testing(ctx);
    settings::authorize<DemoMinter>(&mut cfg, &cap);
    let mut parent = object::new(ctx);
    let rec = record::mint<DemoMinter>(DemoMinter {}, &cfg, &mut parent, release_id, 1, clk, ctx);
    parent.delete();
    settings::destroy_for_testing(cfg, cap);
    rec
}

// === Success ===

#[test]
fun proves_a_recording_on_the_records_release() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let recording = id(@0xBEEF);

    let (rel, cap) = test_release(vector[recording, id(@0xCAFE)], &mut ctx);
    let rec = test_record(rel.id(), &clk, &mut ctx);

    access::prove_recording_for_testing(rec, &rel, recording, &ctx);

    destroy(rel);
    destroy(cap);
    clk.destroy_for_testing();
}

#[test]
fun proves_a_recording_late_in_the_tracklist() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let recording = id(@0xD15C2);

    // The target is the last of four tracks, so a scan that stopped early misses it.
    let (rel, cap) = test_release(vector[id(@0xA1), id(@0xA2), id(@0xB1), recording], &mut ctx);
    let rec = test_record(rel.id(), &clk, &mut ctx);

    access::prove_recording_for_testing(rec, &rel, recording, &ctx);

    destroy(rel);
    destroy(cap);
    clk.destroy_for_testing();
}

#[test]
fun proves_a_copy_of_the_release() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);

    let (rel, cap) = test_release(vector[id(@0xA1), id(@0xA2)], &mut ctx);
    let rec = test_record(rel.id(), &clk, &mut ctx);

    access::prove_release_for_testing(rec, &rel, &ctx);

    destroy(rel);
    destroy(cap);
    clk.destroy_for_testing();
}

#[test]
fun the_asserts_accept_a_matching_record() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let recording = id(@0xBEEF);

    let (rel, cap) = test_release(vector[recording], &mut ctx);
    let rec = test_record(rel.id(), &clk, &mut ctx);

    access::assert_grants_release(&rec, &rel);
    access::assert_grants_recording(&rec, &rel, recording);

    record::destroy(rec);
    destroy(rel);
    destroy(cap);
    clk.destroy_for_testing();
}

// === Composition ===
//
// Link 4 has no runtime negative test, and cannot have one: passing a
// `Composition<X>` alongside a `Recording<_, Y>` is a *type* error, so a
// mismatched pair fails to compile (and, in a PTB, fails type resolution before
// execution). The tests below cover links 2 and 3 as reached through the
// composition entry.

#[test]
fun proves_the_composition_behind_a_recording_on_the_release() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);

    let (comp, comp_cap) = composition::new_for_testing<SONG>(b"Song".to_string(), 1500, &mut ctx);
    let (rec_obj, rec_cap) = recording::new_for_testing<MASTER, SONG>(&mut ctx);

    // The release carries a track for this recording, alongside an unrelated one.
    let (rel, cap) = test_release(vector[id(@0xA1), rec_obj.id()], &mut ctx);
    let record = test_record(rel.id(), &clk, &mut ctx);

    access::prove_composition_for_testing(record, &rel, &rec_obj, &comp, &ctx);

    destroy(comp);
    destroy(comp_cap);
    destroy(rec_obj);
    destroy(rec_cap);
    destroy(rel);
    destroy(cap);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = access::ERecordingNotOnRelease)]
fun a_composition_reached_only_off_the_release_aborts() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);

    let (comp, comp_cap) = composition::new_for_testing<SONG>(b"Song".to_string(), 1500, &mut ctx);
    let (rec_obj, rec_cap) = recording::new_for_testing<MASTER, SONG>(&mut ctx);

    // The recording really is of this composition — it is just not on the release
    // the listener owns, so link 3 fails before link 4 is ever reached.
    let (rel, cap) = test_release(vector[id(@0xA1)], &mut ctx);
    let record = test_record(rel.id(), &clk, &mut ctx);

    access::prove_composition_for_testing(record, &rel, &rec_obj, &comp, &ctx);

    destroy(comp);
    destroy(comp_cap);
    destroy(rec_obj);
    destroy(rec_cap);
    destroy(rel);
    destroy(cap);
    clk.destroy_for_testing();
}

// === Failure ===

#[test, expected_failure(abort_code = access::EWrongRelease)]
fun a_record_for_another_release_aborts() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let recording = id(@0xBEEF);

    // The recording really is on this release — but the sender's record is a copy
    // of a different one, so link 2 fails.
    let (rel, cap) = test_release(vector[recording], &mut ctx);
    let (other, other_cap) = test_release(vector[recording], &mut ctx);
    let rec = test_record(other.id(), &clk, &mut ctx);

    access::prove_recording_for_testing(rec, &rel, recording, &ctx);

    destroy(rel);
    destroy(cap);
    destroy(other);
    destroy(other_cap);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = access::EWrongRelease)]
fun a_record_for_another_release_fails_the_release_proof() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);

    let (rel, cap) = test_release(vector[id(@0xA1)], &mut ctx);
    let (other, other_cap) = test_release(vector[id(@0xA1)], &mut ctx);
    let rec = test_record(other.id(), &clk, &mut ctx);

    access::prove_release_for_testing(rec, &rel, &ctx);

    destroy(rel);
    destroy(cap);
    destroy(other);
    destroy(other_cap);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = access::ERecordingNotOnRelease)]
fun a_recording_absent_from_the_release_aborts() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);

    // The sender owns a real copy of this release — it just does not contain the
    // recording being asked for, so link 3 fails.
    let (rel, cap) = test_release(vector[id(@0xA1), id(@0xA2)], &mut ctx);
    let rec = test_record(rel.id(), &clk, &mut ctx);

    access::prove_recording_for_testing(rec, &rel, id(@0xDEAD), &ctx);

    destroy(rel);
    destroy(cap);
    clk.destroy_for_testing();
}
