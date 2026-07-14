// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A primary record sale — a *Pressing*.
///
/// A `Pressing` is a shared object that presses (mints) and sells numbered `Record`
/// copies of a release, forwarding each payment to the release's address, with no cap
/// on how many may ever be pressed. Each purchase mints a `Record` whose UID is
/// *derived* off the `Pressing`'s own UID (keyed by the 1-based serial number it was
/// pressed at), so every copy is deterministically addressable from its pressing and
/// can be pressed at most once.
///
/// # No access gate
///
/// A pressing never gates *who* may buy. Supply is uncapped and anyone may press a copy
/// while the pressing is live. How "rare" a record becomes is a matter of how its owner
/// engages with it over time (an extension concern), never of manufactured scarcity at
/// the point of sale — so there are no caps, allowlists, auctions, or raffles here.
///
/// # Editions
///
/// A release may have many pressings — a first pressing, a repress, a colored variant.
/// Each is an *edition*: a 0-based run number scoped to the release. Pressing UIDs are
/// themselves *derived* off the shared `PressingRegistry`, keyed by
/// `PressingKey(release_id, edition)`, which gives two things for free:
/// - **deterministic addressing** — a pressing's address is computable from its release
///   and edition, and a record's from its pressing and number; and
/// - **gap-free sequencing** — creating edition `n > 0` asserts edition `n - 1` already
///   exists for that release, and `derived_object::claim` rejects a duplicate edition.
///
/// # Window (the only mechanic)
///
/// A pressing is **immutable** once created: its price and window are fixed. It sells
/// only within `[start_timestamp_ms, end_timestamp_ms]` — the close is optional (`none`
/// = evergreen, always buyable). Liveness is a pure function of the clock; there is no
/// manual pause. To end a limited run, set a close up front; to offer more later, press
/// a new edition.
///
/// # Authority
///
/// Creating a pressing needs the release's `ReleaseAdminCap` (which carries the
/// `release_id`). Minting is authorized separately: this package presents its
/// `MintWitness`, whose type must be on `miso_record`'s `Settings` allowlist. A
/// different shop with different mechanics is just another package with its own
/// witness — same `Record`, no `miso_record` redeploy.
module miso_pressing::pressing;

use bps::bps::{Self, BPS};
use miso::release::{Release, ReleaseAdminCap};
use miso_record::record::{Self, Record};
use miso_record::settings::Settings;
use sui::balance;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::derived_object;
use sui::event::emit;

//=== Structs ===

/// Root object that all `Pressing` UIDs are derived off. Shared once at publish; every
/// `new` claims its pressing off this registry keyed by `PressingKey(release_id, edition)`.
public struct PressingRegistry has key {
    id: UID,
}

/// Key for deriving a `Pressing`'s UID off the `PressingRegistry`: a release's `edition`
/// run number. Scoped by `release_id` so each release owns an independent `0, 1, 2, …`
/// edition sequence.
public struct PressingKey(ID, u32) has copy, drop, store;

/// Witness authorizing `miso_record` mints. Constructible only inside this package,
/// and minted only on `press`'s paid path — so possessing a value of it proves a valid
/// purchase happened. `miso_record::Settings` must authorize this *type* to mint.
public struct MintWitness has drop {}

/// A primary sale of `Record`s for one edition of a release. Immutable once created.
public struct Pressing<phantom Currency> has key {
    id: UID,
    /// The release these records are copies of.
    release_id: ID,
    /// Which pressing run of the release this is (0 = first pressing).
    edition: u32,
    /// How much a buyer must pay per record.
    price: Price,
    /// Optional referral commission. When set *and* a buyer names a referrer, this
    /// fraction of each payment is paid to that referrer out of proceeds (the rest
    /// goes to the release); `none` = no referral program. Fixed at creation.
    referral_commission_rate: Option<BPS>,
    /// Records pressed so far; also the most recently pressed record's number.
    /// Uncapped — a pressing never runs out on quantity.
    quantity_sold: u64,
    /// Unix ms the pressing opens (may be in the future — a scheduled drop). `press`
    /// rejects purchases before it.
    start_timestamp_ms: u64,
    /// Unix ms the pressing closes; `none` = evergreen (always buyable). `press` rejects
    /// purchases after it.
    end_timestamp_ms: Option<u64>,
}

//=== Enums ===

/// Pricing policy for a pressing.
public enum Price has copy, drop, store {
    /// Pay exactly `amount`.
    Fixed { amount: u64 },
    /// Pay at least `amount`; overpayment is forwarded to the release, not refunded.
    Floor { amount: u64 },
}

//=== Events ===

public struct PressingCreatedEvent<phantom Currency> has copy, drop {
    pressing_id: ID,
    release_id: ID,
    edition: u32,
    price_type: vector<u8>,
    price_amount: u64,
    referral_commission_rate: Option<u16>,
    start_timestamp_ms: u64,
    end_timestamp_ms: Option<u64>,
}

public struct RecordPressedEvent<phantom Currency> has copy, drop {
    pressing_id: ID,
    release_id: ID,
    edition: u32,
    record_id: ID,
    number: u64,
    paid: u64,
    buyer: address,
}

/// A referral commission was paid out of a purchase to the buyer's named referrer.
public struct ReferralPaidEvent<phantom Currency> has copy, drop {
    pressing_id: ID,
    release_id: ID,
    /// The record serial this commission was earned on.
    number: u64,
    referral: address,
    buyer: address,
    /// Commission paid, in `Currency`'s smallest unit.
    amount: u64,
}

//=== Errors ===

/// The admin capability does not authorize this pressing's release.
const EUnauthorized: u64 = 0;
/// Payment does not satisfy the pressing's price.
const EInsufficientPayment: u64 = 1;
/// The pressing has not opened yet (`now < start_timestamp_ms`).
const EPressingNotStarted: u64 = 2;
/// The pressing has closed (`now > end_timestamp_ms`).
const EPressingClosed: u64 = 3;
/// The requested `[start, end]` window is empty or already in the past.
const EInvalidWindow: u64 = 4;
/// Editions must be created in sequence: edition `n > 0` requires edition `n - 1` to
/// already exist for this release.
const ENonSequentialEdition: u64 = 5;

//=== Init ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(PressingRegistry { id: object::new(ctx) });
}

//=== Price Constructors ===

/// A fixed price: a buyer must pay exactly `amount`.
public fun new_fixed_price(amount: u64): Price {
    Price::Fixed { amount }
}

/// A floor price: a buyer must pay at least `amount`; overpayment is kept.
public fun new_floor_price(amount: u64): Price {
    Price::Floor { amount }
}

//=== Public Functions ===

/// Create and share a new `Pressing` — edition `edition_hint` of `release` — selling
/// copies at `price` within `[start_timestamp_ms, end_timestamp_ms]`, with no quantity
/// cap. Authorized by the release's admin cap. The pressing is immutable once created.
///
/// `edition_hint` is the run number to create; it must be the next in the release's
/// sequence — edition `n > 0` requires edition `n - 1` to already exist, and reusing an
/// edition aborts — so editions are always gap-free. Pass `0` for a release's first
/// pressing.
///
/// The window is validated against the `Clock`: a bounded `end` must be after both
/// `start` and now (you can't create an already-closed pressing). `start` may be in the
/// future to schedule a drop.
public fun new<Currency>(
    registry: &mut PressingRegistry,
    release: &Release,
    cap: &ReleaseAdminCap,
    price: Price,
    referral_commission_rate: Option<u16>,
    edition_hint: u32,
    start_timestamp_ms: u64,
    end_timestamp_ms: Option<u64>,
    clock: &Clock,
) {
    assert!(cap.release_id() == release.id(), EUnauthorized);
    let release_id = release.id();

    // Validate + wrap the referral rate up front — `bps::new` aborts above 100%.
    let referral_commission_rate = referral_commission_rate.map!(|v| bps::new(v));

    // Editions are gap-free: creating edition n>0 requires n-1 to already exist for
    // this release. `derived_object::claim` below separately rejects a duplicate edition.
    if (edition_hint > 0) {
        assert!(
            derived_object::exists(&registry.id, PressingKey(release_id, edition_hint - 1)),
            ENonSequentialEdition,
        );
    };

    // A bounded window must be non-empty and not already elapsed.
    end_timestamp_ms.do_ref!(|end| {
        assert!(*end > start_timestamp_ms, EInvalidWindow);
        assert!(*end > clock.timestamp_ms(), EInvalidWindow);
    });

    let id = derived_object::claim(&mut registry.id, PressingKey(release_id, edition_hint));

    emit(PressingCreatedEvent<Currency> {
        pressing_id: id.to_inner(),
        release_id,
        edition: edition_hint,
        price_type: price.type_name(),
        price_amount: price.amount(),
        referral_commission_rate: referral_commission_rate.map!(|r| r.value()),
        start_timestamp_ms,
        end_timestamp_ms,
    });

    transfer::share_object(Pressing<Currency> {
        id,
        release_id,
        edition: edition_hint,
        price,
        referral_commission_rate,
        quantity_sold: 0,
        start_timestamp_ms,
        end_timestamp_ms,
    });
}

/// Press (buy) one record from a live pressing — one within its time window.
///
/// `payment` must satisfy the price (exactly, for `Fixed`; at least, for `Floor`) — under
/// `Floor`, anything paid above the floor is kept (a pay-what-you-want tip), not refunded.
/// `referral` optionally names the storefront/fan who drove the sale: when this pressing
/// sets a `referral_commission_rate` *and* a referrer is given, that fraction of the whole
/// payment is paid to the referrer and the remainder is forwarded to the release; otherwise
/// the entire payment goes to the release. The pressed record's number is the 1-based
/// `quantity_sold` count, its UID is derived off the pressing, and it records the pressing's
/// `edition`, the `Currency`, and the amount paid. `settings` must authorize this package's
/// `MintWitness`.
public fun press<Currency>(
    self: &mut Pressing<Currency>,
    payment: Coin<Currency>,
    referral: Option<address>,
    settings: &Settings,
    clock: &Clock,
    ctx: &mut TxContext,
): Record {
    let now = clock.timestamp_ms();
    assert!(now >= self.start_timestamp_ms, EPressingNotStarted);
    self.end_timestamp_ms.do_ref!(|end| assert!(now <= *end, EPressingClosed));

    let paid = payment.value();
    match (self.price) {
        Price::Fixed { amount } => assert!(paid == amount, EInsufficientPayment),
        Price::Floor { amount } => assert!(paid >= amount, EInsufficientPayment),
    };

    self.quantity_sold = self.quantity_sold + 1;
    let number = self.quantity_sold;

    // Split the payment: an optional referral commission is paid to the buyer's named
    // referrer (only when this pressing sets a rate *and* a referrer is given), and the
    // remainder is forwarded to the release's address (funds accumulator) for the release /
    // royalty layer to redeem + split. A free pressing (price 0) skips the send so we never
    // open a zero-value accumulator slot.
    if (paid > 0) {
        let mut proceeds = payment.into_balance();
        self.referral_commission_rate.do_ref!(|rate| referral.do_ref!(|addr| {
            let commission = bps::apply(*rate, paid);
            if (commission > 0) {
                balance::send_funds(proceeds.split(commission), *addr);
                emit(ReferralPaidEvent<Currency> {
                    pressing_id: self.id.to_inner(),
                    release_id: self.release_id,
                    number,
                    referral: *addr,
                    buyer: ctx.sender(),
                    amount: commission,
                });
            }
        }));
        balance::send_funds(proceeds, self.release_id.to_address());
    } else {
        payment.destroy_zero();
    };

    let record = record::mint_derived<MintWitness, Currency>(
        MintWitness {},
        settings,
        &mut self.id,
        self.release_id,
        self.edition,
        number,
        paid,
        ctx,
    );

    emit(RecordPressedEvent<Currency> {
        pressing_id: self.id.to_inner(),
        release_id: self.release_id,
        edition: self.edition,
        record_id: record.id(),
        number,
        paid,
        buyer: ctx.sender(),
    });

    record
}

//=== View Functions ===

public fun id<Currency>(self: &Pressing<Currency>): ID {
    self.id.to_inner()
}

public fun release_id<Currency>(self: &Pressing<Currency>): ID {
    self.release_id
}

public fun edition<Currency>(self: &Pressing<Currency>): u32 {
    self.edition
}

public fun quantity_sold<Currency>(self: &Pressing<Currency>): u64 {
    self.quantity_sold
}

public fun price<Currency>(self: &Pressing<Currency>): u64 {
    self.price.amount()
}

/// The referral commission rate in basis points, or `none` if this pressing runs no
/// referral program.
public fun referral_commission_rate<Currency>(self: &Pressing<Currency>): Option<u16> {
    self.referral_commission_rate.map!(|r| r.value())
}

/// Whether `press` would be accepted right now: inside the time window.
public fun is_live<Currency>(self: &Pressing<Currency>, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    now >= self.start_timestamp_ms
        && (self.end_timestamp_ms.is_none() || now <= *self.end_timestamp_ms.borrow())
}

public fun start_timestamp_ms<Currency>(self: &Pressing<Currency>): u64 {
    self.start_timestamp_ms
}

public fun end_timestamp_ms<Currency>(self: &Pressing<Currency>): Option<u64> {
    self.end_timestamp_ms
}

/// The price amount (the fixed price, or the floor).
public fun amount(self: &Price): u64 {
    match (self) {
        Price::Fixed { amount } => *amount,
        Price::Floor { amount } => *amount,
    }
}

/// A short label for the price policy: `b"Fixed"` or `b"Floor"`.
public fun type_name(self: &Price): vector<u8> {
    match (self) {
        Price::Fixed { .. } => b"Fixed",
        Price::Floor { .. } => b"Floor",
    }
}

//=== Test Helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_registry_for_testing(ctx: &mut TxContext): PressingRegistry {
    PressingRegistry { id: object::new(ctx) }
}

#[test_only]
public fun destroy_registry_for_testing(registry: PressingRegistry) {
    let PressingRegistry { id } = registry;
    id.delete();
}

/// Build an unshared `Pressing` for tests of `press` (real `new` shares it and derives
/// off the registry, which a unit test without a scenario can't retrieve).
#[test_only]
public fun new_for_testing<Currency>(
    release_id: ID,
    edition: u32,
    price: Price,
    referral_commission_rate: Option<BPS>,
    start_timestamp_ms: u64,
    end_timestamp_ms: Option<u64>,
    ctx: &mut TxContext,
): Pressing<Currency> {
    Pressing {
        id: object::new(ctx),
        release_id,
        edition,
        price,
        referral_commission_rate,
        quantity_sold: 0,
        start_timestamp_ms,
        end_timestamp_ms,
    }
}

#[test_only]
public fun destroy_for_testing<Currency>(self: Pressing<Currency>) {
    let Pressing { id, .. } = self;
    id.delete();
}
