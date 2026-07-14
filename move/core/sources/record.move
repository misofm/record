// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The Miso record — an owned, ownable copy of a release.
///
/// Deliberately slim, like `miso_player`: a `Record` is the release it is a copy of,
/// the pressing *edition* it came from, its serial *number* within that pressing, and
/// what was paid for it. It is an owned object, and everything else — pressing logic,
/// statistics, vouchers — is added by extensions that attach to the record's `UID` via
/// dynamic fields. The release is referenced by `ID` only, so the core has no
/// dependency on the protocol; extensions that need the typed `Release` bring that
/// dependency themselves.
///
/// `(release_id, edition, number)` locates a record globally: `edition` says which
/// pressing run of the release (0 = first pressing, 1 = repress, …), `number` its
/// serial within that run. `purchase_currency` / `purchase_price` record what the buyer
/// paid (the coin type and the exact amount — including any over-floor tip). Both the
/// numbering and the purchase terms are supplied by the minting package, not the core.
///
/// **Minting is gated; possession governs the rest.** A record is only ever brought
/// into being through `mint` / `mint_derived`, each of which requires a *witness*
/// whose type is authorized in `Settings` (see `miso_record::settings`). This is the
/// single seam that lets sale mechanics live in *their own* packages — a `Pressing`,
/// an auction, a giveaway — without this package depending on any of them, and without
/// letting arbitrary code forge records. Once a record exists, authority is
/// possession: only the owner can produce a `&mut Record`, so `uid_mut` is fully
/// open — no capability, no allowlist.
module miso_record::record;

use miso_record::settings::{Self, Settings};
use std::type_name::{Self, TypeName};
use sui::derived_object;
use sui::event::emit;

//=== Structs ===

public struct Record has key, store {
    id: UID,
    release_id: ID,
    /// Which pressing run of the release this copy came from (0 = first pressing).
    edition: u32,
    /// Serial number within the pressing (1-based).
    number: u64,
    /// The coin type the buyer paid in.
    purchase_currency: TypeName,
    /// The exact amount paid (for a floor price, includes any tip above the floor).
    purchase_price: u64,
}

/// Key for deriving a `Record`'s UID off a parent object (e.g. a `Pressing`). The
/// `number` makes each record deterministically addressable from the parent.
public struct RecordKey(u64) has copy, drop, store;

//=== Events ===

public struct RecordCreatedEvent has copy, drop {
    record_id: ID,
    release_id: ID,
    edition: u32,
    number: u64,
    purchase_currency: TypeName,
    purchase_price: u64,
    created_by: address,
}

public struct RecordDestroyedEvent has copy, drop {
    record_id: ID,
    release_id: ID,
    edition: u32,
    number: u64,
}

//=== Errors ===

/// The witness type presented is not authorized to mint records.
const ENotAuthorized: u64 = 0;

//=== Public Functions ===

/// Mint a record of `release_id` (pressing `edition`, serial `number`) on a fresh UID,
/// paid for with `purchase_price` of `Currency`.
///
/// `W` is a witness minted by the caller's package; its *type* must be authorized in
/// `settings`. Passing an unauthorized witness aborts. The witness is consumed, so
/// the caller can gate its construction (e.g. behind payment) to control who mints.
public fun mint<W: drop, Currency>(
    _w: W,
    settings: &Settings,
    release_id: ID,
    edition: u32,
    number: u64,
    purchase_price: u64,
    ctx: &mut TxContext,
): Record {
    assert!(settings.is_authorized<W>(), ENotAuthorized);
    let record = Record {
        id: object::new(ctx),
        release_id,
        edition,
        number,
        purchase_currency: type_name::with_defining_ids<Currency>(),
        purchase_price,
    };
    emit_created(&record, ctx);
    record
}

/// Mint a record whose UID is *derived* off `parent` (e.g. a `Pressing`'s UID) keyed
/// by `number`. Deterministic and collision-checked: `derived_object::claim` aborts if
/// `RecordKey(number)` was already claimed off this parent, so a given number can be
/// minted at most once. Authorization works exactly as in `mint`.
public fun mint_derived<W: drop, Currency>(
    _w: W,
    settings: &Settings,
    parent: &mut UID,
    release_id: ID,
    edition: u32,
    number: u64,
    purchase_price: u64,
    ctx: &TxContext,
): Record {
    assert!(settings.is_authorized<W>(), ENotAuthorized);
    let record = Record {
        id: derived_object::claim(parent, RecordKey(number)),
        release_id,
        edition,
        number,
        purchase_currency: type_name::with_defining_ids<Currency>(),
        purchase_price,
    };
    emit_created(&record, ctx);
    record
}

/// Destroy a record. The caller is responsible for detaching any extensions first;
/// dynamic fields left attached become unreachable.
public fun destroy(self: Record) {
    let record_id = self.id();
    let Record { id, release_id, edition, number, purchase_currency: _, purchase_price: _ } = self;
    id.delete();
    emit(RecordDestroyedEvent { record_id, release_id, edition, number });
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

public fun edition(self: &Record): u32 {
    self.edition
}

public fun number(self: &Record): u64 {
    self.number
}

public fun purchase_currency(self: &Record): TypeName {
    self.purchase_currency
}

public fun purchase_price(self: &Record): u64 {
    self.purchase_price
}

/// True if `self` was minted via `mint_derived` off `parent` (e.g. a `Pressing`'s ID)
/// at its own `number`. Because a derived record's address is `derive_address(parent,
/// RecordKey(number))`, provenance is verifiable on-chain from the record alone given
/// a candidate parent — no stored parent id needed. Returns false for records minted
/// on a fresh UID via `mint` (gifts, airdrops).
public fun is_derived_from(self: &Record, parent: ID): bool {
    derived_object::derive_address(parent, RecordKey(self.number)) == self.id.to_address()
}

//=== Private Functions ===

fun emit_created(record: &Record, ctx: &TxContext) {
    emit(RecordCreatedEvent {
        record_id: record.id(),
        release_id: record.release_id,
        edition: record.edition,
        number: record.number,
        purchase_currency: record.purchase_currency,
        purchase_price: record.purchase_price,
        created_by: ctx.sender(),
    });
}
