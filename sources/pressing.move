// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

/// One edition of a Miso release and the issuance boundary for its Records.
///
/// A Pressing derives from its Release at `PressingKey(edition)`. Editions start
/// at 1 and are created in order. Each Pressing owns an edition-local Record
/// sequence, a positive immutable `max_supply`, and the distributor witness
/// types allowed to mint. Distributors own delivery mechanics.
module record::pressing;

// === Imports ===

use musicos::release::{Release, ReleaseAdminCap};
use record::record::{Self, Record};
use std::type_name::{Self, TypeName};
use sui::{derived_object, event::emit, vec_set::{Self, VecSet}};

// === Errors ===

const EUnauthorized: u64 = 0;
const EInvalidEdition: u64 = 1;
const EInvalidMaxSupply: u64 = 2;
const EDistributorNotAuthorized: u64 = 3;
const EMaxSupplyReached: u64 = 4;
const EInvalidPurchasePrice: u64 = 5;
const EPreviousEditionMissing: u64 = 6;

// === Structs ===

/// One edition's Record namespace, supply, cap, and authorized distributors.
public struct Pressing has key {
    id: UID,
    release_id: ID,
    edition: u16,
    /// Records issued so far; also the last allocated number.
    supply: u32,
    /// Positive, immutable lifetime issuance ceiling.
    max_supply: u32,
    /// Defining types of the distributor witnesses allowed to mint.
    distributors: VecSet<TypeName>,
}

/// Authority over one Pressing's distributors and extensions.
public struct PressingAdminCap has key, store {
    id: UID,
    pressing_id: ID,
}

public struct PressingKey(u16) has copy, drop, store;

public struct PressingAdminCapKey() has copy, drop, store;

// === Events ===

public struct PressingCreatedEvent has copy, drop {
    pressing_id: ID,
    release_id: ID,
    edition: u16,
    max_supply: u32,
}

public struct PressingDistributorAuthorizedEvent<phantom Distributor> has copy, drop {
    pressing_id: ID,
}

public struct PressingDistributorRevokedEvent<phantom Distributor> has copy, drop {
    pressing_id: ID,
}

/// The buyer is the transaction sender; the time is the transaction's.
public struct RecordPurchasedEvent<phantom Distributor, phantom Currency> has copy, drop {
    record_id: ID,
    pressing_id: ID,
    number: u32,
    purchase_price: u64,
}

// === Public Functions ===

/// Creates `edition` of the Release. Aborts unless `edition` is 1 or the
/// previous edition exists, and unless `max_supply` is positive.
public fun new(
    release: &mut Release,
    release_cap: &ReleaseAdminCap,
    edition: u16,
    max_supply: u32,
): (Pressing, PressingAdminCap) {
    assert!(edition > 0, EInvalidEdition);
    assert!(max_supply > 0, EInvalidMaxSupply);

    let release_id = object::id(release);
    let release_uid = release.uid_mut(release_cap);
    assert!(
        edition == 1 || derived_object::exists(release_uid, PressingKey(edition - 1)),
        EPreviousEditionMissing,
    );
    let mut id = derived_object::claim(release_uid, PressingKey(edition));
    let pressing_id = id.to_inner();
    let admin_cap = PressingAdminCap {
        id: derived_object::claim(&mut id, PressingAdminCapKey()),
        pressing_id,
    };

    emit(PressingCreatedEvent { pressing_id, release_id, edition, max_supply });

    let pressing = Pressing {
        id,
        release_id,
        edition,
        supply: 0,
        max_supply,
        distributors: vec_set::empty(),
    };
    (pressing, admin_cap)
}

/// Shares a Pressing after configuring its distributors.
public fun share(self: Pressing) {
    transfer::share_object(self);
}

/// Mints the next Record for an authorized distributor witness. The caller
/// cannot choose the number; the distributor delivers the returned Record.
public fun mint<Distributor: drop, Currency>(
    self: &mut Pressing,
    _: Distributor,
    purchase_price: u64,
): Record {
    assert!(self.is_distributor_authorized<Distributor>(), EDistributorNotAuthorized);
    assert!(purchase_price > 0, EInvalidPurchasePrice);
    assert!(self.supply < self.max_supply, EMaxSupplyReached);

    self.supply = self.supply + 1;
    let number = self.supply;
    let record = record::new<Currency>(
        &mut self.id,
        self.release_id,
        self.edition,
        number,
        purchase_price,
    );
    emit(RecordPurchasedEvent<Distributor, Currency> {
        record_id: object::id(&record),
        pressing_id: self.id.to_inner(),
        number,
        purchase_price,
    });
    record
}

// === View Functions ===

public fun release_id(self: &Pressing): ID {
    self.release_id
}

public fun edition(self: &Pressing): u16 {
    self.edition
}

public fun supply(self: &Pressing): u32 {
    self.supply
}

public fun max_supply(self: &Pressing): u32 {
    self.max_supply
}

public fun is_distributor_authorized<Distributor: drop>(self: &Pressing): bool {
    self.distributors.contains(&type_name::with_defining_ids<Distributor>())
}

public fun pressing_id(cap: &PressingAdminCap): ID {
    cap.pressing_id
}

/// The address of `edition`'s Pressing under `release_id`.
public fun derive_address(release_id: ID, edition: u16): address {
    derived_object::derive_address(release_id, PressingKey(edition))
}

public fun derive_admin_cap_address(pressing_id: ID): address {
    derived_object::derive_address(pressing_id, PressingAdminCapKey())
}

public fun uid(self: &Pressing): &UID {
    &self.id
}

// === Admin Functions ===

/// Authorizes witness type `Distributor` to mint. Idempotent.
public fun authorize_distributor<Distributor: drop>(
    self: &mut Pressing,
    cap: &PressingAdminCap,
) {
    self.authorize(cap);
    let distributor = type_name::with_defining_ids<Distributor>();
    if (self.distributors.contains(&distributor)) return;
    self.distributors.insert(distributor);
    emit(PressingDistributorAuthorizedEvent<Distributor> { pressing_id: cap.pressing_id });
}

/// Revokes witness type `Distributor`. Idempotent.
public fun revoke_distributor<Distributor: drop>(self: &mut Pressing, cap: &PressingAdminCap) {
    self.authorize(cap);
    let distributor = type_name::with_defining_ids<Distributor>();
    if (!self.distributors.contains(&distributor)) return;
    self.distributors.remove(&distributor);
    emit(PressingDistributorRevokedEvent<Distributor> { pressing_id: cap.pressing_id });
}

/// Cap-gated UID access, e.g. for distributor objects derived from the Pressing.
public fun uid_mut(self: &mut Pressing, cap: &PressingAdminCap): &mut UID {
    self.authorize(cap);
    &mut self.id
}

// === Private Functions ===

fun authorize(self: &Pressing, cap: &PressingAdminCap) {
    assert!(cap.pressing_id == self.id.to_inner(), EUnauthorized);
}

// === Test Functions ===

/// A Pressing outside any Release, skipping the edition-order check.
#[test_only]
public fun new_for_testing(
    release_id: ID,
    edition: u16,
    max_supply: u32,
    ctx: &mut TxContext,
): (Pressing, PressingAdminCap) {
    let mut id = object::new(ctx);
    let pressing_id = id.to_inner();
    let admin_cap = PressingAdminCap {
        id: derived_object::claim(&mut id, PressingAdminCapKey()),
        pressing_id,
    };
    let pressing = Pressing {
        id,
        release_id,
        edition,
        supply: 0,
        max_supply,
        distributors: vec_set::empty(),
    };
    (pressing, admin_cap)
}

#[test_only]
public fun foreign_admin_cap_for_testing(pressing_id: ID, ctx: &mut TxContext): PressingAdminCap {
    PressingAdminCap { id: object::new(ctx), pressing_id }
}

#[test_only]
public fun created_event_fields(event: &PressingCreatedEvent): (ID, ID, u16, u32) {
    (event.pressing_id, event.release_id, event.edition, event.max_supply)
}

#[test_only]
public fun authorized_event_pressing_id<Distributor>(
    event: &PressingDistributorAuthorizedEvent<Distributor>,
): ID {
    event.pressing_id
}

#[test_only]
public fun revoked_event_pressing_id<Distributor>(
    event: &PressingDistributorRevokedEvent<Distributor>,
): ID {
    event.pressing_id
}

#[test_only]
public fun purchased_event_fields<Distributor, Currency>(
    event: &RecordPurchasedEvent<Distributor, Currency>,
): (ID, ID, u32, u64) {
    (event.record_id, event.pressing_id, event.number, event.purchase_price)
}
