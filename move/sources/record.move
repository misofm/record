// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The Miso record — an owned, ownable copy of a release.
///
/// Maximally slim, like `miso_player`: a `Record` is the release it is a copy of and
/// the moment it was minted. Those are the only facts fixed at birth, true forever,
/// and meaningful without a namespace. Everything else that makes one copy
/// different from another — playtime, statistics, purchase receipts, vouchers — is
/// contextual: it is applied at mint time or accrued over the record's life, so it
/// lives in dynamic fields attached to the record's `UID` by extensions, never in the
/// struct. The release is referenced by `ID` only, so the core has no dependency on
/// the protocol; extensions that need the typed `Release` bring that dependency
/// themselves.
///
/// The struct deliberately holds no serial number. A serial is only meaningful inside
/// the sequence that issued it — two sale packages for the same release each count
/// from 1 — so it is the *issuer's* vocabulary, not the record's identity, and the
/// issuing package attaches it as its own dynamic field (see `miso_pressing::certificate`).
/// The core keeps serials as pure *addressing*: every record's UID is derived off its
/// minting parent keyed by `RecordKey(number)`, so a slot can be claimed at most once
/// per parent and a record's provenance is verifiable from address math alone
/// (`derive_id`). `created_at_ms` needs no such namespace — a birth date is a fact
/// about the record itself — and it is stamped by this module off the shared `Clock`,
/// so a minting package cannot forge it.
///
/// **Minting is gated; possession governs the rest.** A record is only ever brought
/// into being through `mint`, which requires a *witness* whose type is authorized in
/// `Settings` (see `miso_record::settings`). This is the single seam that lets sale
/// mechanics live in *their own* packages — a drop, an auction, a giveaway — without
/// this package depending on any of them, and without letting arbitrary code forge
/// records. Once a record exists, authority is possession: only the owner can produce
/// a `&mut Record`, so `uid_mut` is fully open — no capability, no allowlist.
module miso_record::record;

use miso_record::settings::Settings;
use sui::clock::Clock;
use sui::derived_object;
use sui::event::emit;

//=== Structs ===

public struct Record has key, store {
    id: UID,
    release_id: ID,
    /// When this record was minted, ms since Unix epoch. Stamped off the `Clock` by
    /// this module — never supplied by the minter.
    created_at_ms: u64,
}

/// Key for deriving a `Record`'s UID off a parent object (e.g. a `Pressing`). The
/// `number` makes each record deterministically addressable from the parent.
public struct RecordKey(u64) has copy, drop, store;

//=== Events ===

public struct RecordCreatedEvent has copy, drop {
    record_id: ID,
    release_id: ID,
    /// The derived-claim slot the record was minted at. Context for indexers — the
    /// struct itself does not carry it.
    number: u64,
    created_at_ms: u64,
    created_by: address,
}

public struct RecordDestroyedEvent has copy, drop {
    record_id: ID,
    release_id: ID,
}

//=== Errors ===

/// The witness type presented is not authorized to mint records.
const ENotAuthorized: u64 = 0;

//=== Public Functions ===

/// Mint a record of `release_id`, its UID *derived* off `parent` (e.g. a `Pressing`'s
/// UID) keyed by `number`. This is the only way a record comes into being: every
/// record is deterministically addressable from its minting context, and
/// `derived_object::claim` aborts if `RecordKey(number)` was already claimed off this
/// parent, so a slot can be minted at most once per parent. `number` is the claim
/// slot only — the record does not store it; a serial is the issuing package's
/// vocabulary, attached as that package's own dynamic field if it wants one. (There
/// is deliberately no fresh-UID mint — a gifting or airdrop package derives off an
/// object of its own.)
///
/// `W` is a witness minted by the caller's package; its *type* must be authorized in
/// `settings`. Passing an unauthorized witness aborts. The witness is consumed, so
/// the caller can gate its construction (e.g. behind payment) to control who mints.
public fun mint<W: drop>(
    _w: W,
    settings: &Settings,
    parent: &mut UID,
    release_id: ID,
    number: u64,
    clock: &Clock,
    ctx: &TxContext,
): Record {
    assert!(settings.is_authorized<W>(), ENotAuthorized);
    let record = Record {
        id: derived_object::claim(parent, RecordKey(number)),
        release_id,
        created_at_ms: clock.timestamp_ms(),
    };
    emit(RecordCreatedEvent {
        record_id: record.id(),
        release_id: record.release_id,
        number,
        created_at_ms: record.created_at_ms,
        created_by: ctx.sender(),
    });
    record
}

/// Destroy a record. The caller is responsible for detaching any extensions first;
/// dynamic fields left attached become unreachable.
public fun destroy(self: Record) {
    let record_id = self.id();
    let Record { id, release_id, .. } = self;
    id.delete();
    emit(RecordDestroyedEvent { record_id, release_id });
}

//=== Extension access (possession is authority) ===

/// Immutable UID access for extensions to read their dynamic fields.
public fun uid(self: &Record): &UID {
    &self.id
}

/// Mutable UID access for extensions to attach/mutate their dynamic fields. Open by
/// design: holding `&mut Record` already proves ownership.
public fun uid_mut(self: &mut Record): &mut UID {
    &mut self.id
}

//=== View Functions ===

public fun id(self: &Record): ID {
    self.id.to_inner()
}

public fun release_id(self: &Record): ID {
    self.release_id
}

public fun created_at_ms(self: &Record): u64 {
    self.created_at_ms
}

/// The address a record derived off `parent` at claim slot `number` occupies — pure
/// address math, computable before the record exists. Also the provenance check:
/// a record was minted off `parent` at `number` iff `derive_id(parent, number)` is
/// its id. (The record does not store its slot — the issuing package's serial field
/// says which number to check.)
public fun derive_id(parent: ID, number: u64): ID {
    derived_object::derive_address(parent, RecordKey(number)).to_id()
}
