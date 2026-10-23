// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

module record::pressing;

// === Imports ===

use std::type_name::{Self, TypeName};
use sui::{clock::Clock, derived_object, event::emit, vec_set::{Self, VecSet}};
use miso_music::release::{Release, ReleaseAdminCap};
use record::record::{Self, Record};

// === Errors ===

const EUnauthorized: u64 = 0;
const EInvalidEdition: u64 = 1;
const EInvalidMaxSupply: u64 = 2;
const EDistributorNotAuthorized: u64 = 3;
const EMaxSupplyReached: u64 = 4;
const EPreviousEditionMissing: u64 = 5;

// === Structs ===

public struct Pressing has key {
    id: UID,
    release_id: ID,
    edition: u16,
    supply: u32,
    max_supply: u32,
    distributors: VecSet<TypeName>,
}

public struct PressingAdminCap has key, store {
    id: UID,
    pressing_id: ID,
}

public struct PressingKey(u16) has copy, drop, store;

public struct PressingAdminCapKey() has copy, drop, store;

// === Events ===

public struct PressingCreatedEvent has copy, drop {
    pressing_id: ID,
    admin_cap_id: ID,
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

public struct RecordPurchasedEvent<phantom Distributor, phantom Currency> has copy, drop {
    record_id: ID,
    pressing_id: ID,
    number: u32,
    purchase_price: u64,
    purchased_at_ms: u64,
}

// === Method Aliases ===

public use fun pressing_admin_cap_pressing_id as PressingAdminCap.pressing_id;

// === Public Functions ===

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

    emit(PressingCreatedEvent {
        pressing_id,
        admin_cap_id: object::id(&admin_cap),
        release_id,
        edition,
        max_supply,
    });

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

public fun share(self: Pressing) {
    transfer::share_object(self);
}

public fun press<Distributor: drop, Currency>(
    self: &mut Pressing,
    _: Distributor,
    purchase_price: u64,
    clock: &Clock,
): Record {
    assert!(self.is_distributor_authorized<Distributor>(), EDistributorNotAuthorized);
    assert!(self.supply < self.max_supply, EMaxSupplyReached);

    self.supply = self.supply + 1;
    let number = self.supply;
    let record = record::new<Currency>(
        &mut self.id,
        self.release_id,
        self.edition,
        number,
        purchase_price,
        clock,
    );
    emit(RecordPurchasedEvent<Distributor, Currency> {
        record_id: object::id(&record),
        pressing_id: self.id.to_inner(),
        number,
        purchase_price,
        purchased_at_ms: record.purchased_at_ms(),
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

public fun distributors(self: &Pressing): &VecSet<TypeName> {
    &self.distributors
}

public fun is_distributor_authorized<Distributor: drop>(self: &Pressing): bool {
    self.distributors.contains(&type_name::with_defining_ids<Distributor>())
}

public fun derive_address(release_id: ID, edition: u16): address {
    derived_object::derive_address(release_id, PressingKey(edition))
}

public fun uid(self: &Pressing): &UID {
    &self.id
}

public fun pressing_admin_cap_pressing_id(cap: &PressingAdminCap): ID {
    cap.pressing_id
}

public fun derive_admin_cap_address(pressing_id: ID): address {
    derived_object::derive_address(pressing_id, PressingAdminCapKey())
}

// === Admin Functions ===

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

public fun revoke_distributor<Distributor: drop>(self: &mut Pressing, cap: &PressingAdminCap) {
    self.authorize(cap);
    let distributor = type_name::with_defining_ids<Distributor>();
    if (!self.distributors.contains(&distributor)) return;
    self.distributors.remove(&distributor);
    emit(PressingDistributorRevokedEvent<Distributor> { pressing_id: cap.pressing_id });
}

public fun uid_mut(self: &mut Pressing, cap: &PressingAdminCap): &mut UID {
    self.authorize(cap);
    &mut self.id
}

// === Private Functions ===

fun authorize(self: &Pressing, cap: &PressingAdminCap) {
    assert!(cap.pressing_id == self.id.to_inner(), EUnauthorized);
}

// === Test Functions ===

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
public fun set_supply_for_testing(self: &mut Pressing, supply: u32) {
    self.supply = supply;
}

#[test_only]
public fun foreign_admin_cap_for_testing(pressing_id: ID, ctx: &mut TxContext): PressingAdminCap {
    PressingAdminCap { id: object::new(ctx), pressing_id }
}

#[test_only]
public fun created_event_fields(event: &PressingCreatedEvent): (ID, ID, ID, u16, u32) {
    (event.pressing_id, event.admin_cap_id, event.release_id, event.edition, event.max_supply)
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
): (ID, ID, u32, u64, u64) {
    (
        event.record_id,
        event.pressing_id,
        event.number,
        event.purchase_price,
        event.purchased_at_ms,
    )
}
