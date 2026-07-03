// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A primary record sale — a *Drop*.
///
/// A `Drop` is a shared object that sells `Record`s for a release, forwarding
/// each payment to the release's address, with no cap on how many may ever be
/// sold. Each purchase mints a `Record` whose UID is *derived* off the `Drop`'s
/// own UID (keyed by the 1-based serial number it was sold at), so every sold
/// record is deterministically addressable from the drop and can be minted at
/// most once.
///
/// A release may have any number of drops — each is an independent shared object
/// (e.g. a restock, or a different price/currency); there is no ordering or
/// numbering between them.
///
/// A drop tracks `quantity_sold` and `start_timestamp_ms`. Together with a sold
/// record's own `number`, these let a downstream campaign (e.g. a SEAL access
/// condition) derive on-chain whether a given record was among the first N sold,
/// or whether its drop started before some cutoff — without the core needing any
/// upfront supply commitment or first-class notion of "edition"/scarcity tier.
///
/// Authority is the release's `ReleaseAdminCap`: there is no separate drop cap.
/// Creating, pausing, or resuming a drop only needs the cap, since the cap carries
/// the `release_id` the drop records.
module miso_record::drop;

use miso::release::{Release, ReleaseAdminCap};
use miso_record::record::{Self, Record};
use sui::balance;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::event::emit;

//=== Structs ===

/// A primary sale of `Record`s for a release.
public struct Drop<phantom Currency> has key {
    id: UID,
    /// The release these records are copies of.
    release_id: ID,
    /// Open / Paused lifecycle.
    state: DropState,
    /// How much a buyer must pay per record.
    price: Price,
    /// Records sold so far; also the most recently minted record's number.
    /// Uncapped — a drop never runs out and never auto-closes.
    quantity_sold: u64,
    /// Unix ms timestamp (from the shared `Clock`) when this drop was created.
    /// Lets a campaign derive on-chain whether the drop itself started before a
    /// given cutoff.
    start_timestamp_ms: u64,
}

//=== Enums ===

/// Lifecycle of a drop.
public enum DropState has copy, drop, store {
    /// Accepting purchases.
    Open,
    /// Temporarily not accepting purchases; can be reopened.
    Paused,
}

/// Pricing policy for a drop.
public enum Price has copy, drop, store {
    /// Pay exactly `amount`.
    Fixed { amount: u64 },
    /// Pay at least `amount`; overpayment is forwarded to the release, not refunded.
    Floor { amount: u64 },
}

//=== Events ===

public struct DropCreatedEvent<phantom Currency> has copy, drop {
    drop_id: ID,
    release_id: ID,
    price_type: vector<u8>,
    price_amount: u64,
    start_timestamp_ms: u64,
}

public struct RecordBoughtEvent<phantom Currency> has copy, drop {
    drop_id: ID,
    release_id: ID,
    record_id: ID,
    number: u64,
    paid: u64,
    buyer: address,
}

public struct DropStateChangedEvent<phantom Currency> has copy, drop {
    drop_id: ID,
    release_id: ID,
    paused: bool,
}

//=== Errors ===

/// The admin capability does not authorize this drop's release.
const EUnauthorized: u64 = 0;
/// The drop is not Open (it's paused).
const EDropNotOpen: u64 = 1;
/// Payment does not satisfy the drop's price.
const EInsufficientPayment: u64 = 2;
/// Selling one more record would overflow the u32 record-number space.
const EQuantitySoldOverflow: u64 = 3;

/// Largest value `quantity_sold` may reach — bounded so every minted
/// `Record.number: u32` fits and the `quantity_sold as u32` cast can never
/// overflow.
const MAX_RECORD_NUMBER: u64 = 0xFFFF_FFFF;

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

/// Create and share a new `Drop` selling copies of `release` at `price`, with no
/// cap on quantity. Authorized by the release's admin cap. `start_timestamp_ms`
/// is read from the shared `Clock`, not caller-supplied, so downstream campaigns
/// can trust it.
public fun new<Currency>(
    release: &Release,
    cap: &ReleaseAdminCap,
    price: Price,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(cap.release_id() == release.id(), EUnauthorized);

    let release_id = release.id();
    let id = object::new(ctx);
    let start_timestamp_ms = clock.timestamp_ms();

    emit(DropCreatedEvent<Currency> {
        drop_id: id.to_inner(),
        release_id,
        price_type: price.type_name(),
        price_amount: price.amount(),
        start_timestamp_ms,
    });

    transfer::share_object(Drop<Currency> {
        id,
        release_id,
        state: DropState::Open,
        price,
        quantity_sold: 0,
        start_timestamp_ms,
    });
}

/// Buy one record from an open drop.
///
/// `payment` must satisfy the price (exactly, for `Fixed`; at least, for
/// `Floor`). The ENTIRE payment is forwarded to the release's address — under
/// `Floor`, anything paid above the floor is kept (a pay-what-you-want tip),
/// not refunded. The minted record's number is the 1-based `quantity_sold`
/// count, and its UID is derived off the drop.
public fun buy<Currency>(
    self: &mut Drop<Currency>,
    payment: Coin<Currency>,
    ctx: &mut TxContext,
): Record {
    assert!(self.state == DropState::Open, EDropNotOpen);
    assert!(self.quantity_sold < MAX_RECORD_NUMBER, EQuantitySoldOverflow);

    let paid = payment.value();
    match (self.price) {
        Price::Fixed { amount } => assert!(paid == amount, EInsufficientPayment),
        Price::Floor { amount } => assert!(paid >= amount, EInsufficientPayment),
    };

    // Forward the entire payment to the release's address (funds accumulator);
    // the release / royalty layer redeems + splits it downstream. A free drop
    // (price 0) skips the send so we never open a zero-value accumulator slot.
    if (paid > 0) {
        balance::send_funds(payment.into_balance(), self.release_id.to_address());
    } else {
        payment.destroy_zero();
    };
    self.quantity_sold = self.quantity_sold + 1;

    let record = record::new_derived(
        self.release_id,
        self.quantity_sold as u32,
        &mut self.id,
        ctx,
    );

    emit(RecordBoughtEvent<Currency> {
        drop_id: self.id.to_inner(),
        release_id: self.release_id,
        record_id: record.id(),
        number: self.quantity_sold,
        paid,
        buyer: ctx.sender(),
    });

    record
}

/// Pause (`paused = true`) or resume (`paused = false`) a drop. Authorized by the
/// release admin cap.
public fun set_state<Currency>(self: &mut Drop<Currency>, cap: &ReleaseAdminCap, paused: bool) {
    self.authorize(cap);

    self.state = if (paused) DropState::Paused else DropState::Open;

    emit(DropStateChangedEvent<Currency> {
        drop_id: self.id.to_inner(),
        release_id: self.release_id,
        paused,
    });
}

//=== View Functions ===

public fun id<Currency>(self: &Drop<Currency>): ID {
    self.id.to_inner()
}

public fun release_id<Currency>(self: &Drop<Currency>): ID {
    self.release_id
}

public fun quantity_sold<Currency>(self: &Drop<Currency>): u64 {
    self.quantity_sold
}

public fun price<Currency>(self: &Drop<Currency>): u64 {
    self.price.amount()
}

public fun is_open<Currency>(self: &Drop<Currency>): bool {
    self.state == DropState::Open
}

public fun is_paused<Currency>(self: &Drop<Currency>): bool {
    self.state == DropState::Paused
}

public fun start_timestamp_ms<Currency>(self: &Drop<Currency>): u64 {
    self.start_timestamp_ms
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

//=== Private Functions ===

/// Assert the admin cap authorizes this drop's release. The cap carries the
/// `release_id` it controls (a public accessor on `ReleaseAdminCap`), so no
/// `&mut Release` is needed for cap-only operations.
fun authorize<Currency>(self: &Drop<Currency>, cap: &ReleaseAdminCap) {
    assert!(cap.release_id() == self.release_id, EUnauthorized);
}
