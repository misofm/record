// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One edition of a Miso release and the complete lifecycle boundary for its
/// Records.
///
/// A release may have many Pressings, one at each `PressingKey(edition)`. Each
/// Pressing owns an independent, 1-based Record sequence, an optional immutable
/// maximum supply, and the set of distributor witness types allowed to mint from
/// that edition. Distributors own delivery mechanics; the Pressing owns issuance.
module miso_record::pressing;

use miso::release::{Release, ReleaseAdminCap};
use miso_record::record::{Self, Record};
use std::type_name::{Self, TypeName};
use sui::clock::Clock;
use sui::derived_object;
use sui::event::emit;
use sui::vec_set::{Self, VecSet};

//=== Constants ===

const VERSION: u64 = 1;

//=== Structs ===

/// Key for deriving one edition's Pressing from its Release.
public struct PressingKey(u64) has copy, drop, store;

/// Key for deriving the capability that administers a Pressing.
public struct PressingAdminCapKey() has copy, drop, store;

/// One edition's Record namespace, supply, cap, and authorized distributors.
public struct Pressing has key {
    id: UID,
    version: u64,
    release_id: ID,
    edition: u64,
    supply: u64,
    max_supply: Option<u64>,
    distributors: VecSet<TypeName>,
}

/// Authority to add or remove distributors and extend a specific Pressing.
public struct PressingAdminCap has key, store {
    id: UID,
    pressing_id: ID,
}

//=== Events ===

public struct PressingCreated has copy, drop {
    pressing_id: ID,
    release_id: ID,
    edition: u64,
    max_supply: Option<u64>,
}

public struct DistributorAuthorized has copy, drop {
    pressing_id: ID,
    distributor: TypeName,
}

public struct DistributorRevoked has copy, drop {
    pressing_id: ID,
    distributor: TypeName,
}

//=== Errors ===

#[error(code = 0)]
const EUnauthorized: vector<u8> = b"The admin capability does not control this Pressing";

#[error(code = 1)]
const EInvalidEdition: vector<u8> = b"A Pressing edition must be greater than zero";

#[error(code = 2)]
const EInvalidMaxSupply: vector<u8> = b"A capped Pressing must allow at least one Record";

#[error(code = 3)]
const EDistributorNotAuthorized: vector<u8> = b"The distributor is not authorized for this Pressing";

#[error(code = 4)]
const EMaxSupplyReached: vector<u8> = b"The Pressing has reached its maximum supply";

#[error(code = 5)]
const EWrongVersion: vector<u8> = b"The Pressing object version is not supported by this package version";

//=== Public Functions ===

/// Create one edition's Pressing under its Release.
///
/// `edition` is 1-based. `max_supply = none()` creates an uncapped edition;
/// `some(quantity)` creates a permanently capped edition. The Pressing and its
/// admin capability are returned for composition before the caller shares the
/// Pressing and custodies the capability.
public fun new(
    release: &mut Release,
    release_cap: &ReleaseAdminCap,
    edition: u64,
    max_supply: Option<u64>,
): (Pressing, PressingAdminCap) {
    assert!(edition > 0, EInvalidEdition);
    max_supply.do_ref!(|max| assert!(*max > 0, EInvalidMaxSupply));

    let release_id = object::id(release);
    let mut id = derived_object::claim(
        release.uid_mut(release_cap),
        PressingKey(edition),
    );
    let pressing_id = id.to_inner();
    let admin_cap = PressingAdminCap {
        id: derived_object::claim(&mut id, PressingAdminCapKey()),
        pressing_id,
    };

    emit(PressingCreated {
        pressing_id,
        release_id,
        edition,
        max_supply,
    });

    (
        Pressing {
            id,
            version: VERSION,
            release_id,
            edition,
            supply: 0,
            max_supply,
            distributors: vec_set::empty(),
        },
        admin_cap,
    )
}

/// Share a newly created Pressing after configuring its distributors.
public fun share(self: Pressing) {
    transfer::share_object(self);
}

/// Authorize distributor witness type `Distributor` for this edition.
/// Reauthorizing an existing distributor is a no-op.
public fun authorize_distributor<Distributor: drop>(
    self: &mut Pressing,
    cap: &PressingAdminCap,
) {
    self.authorize(cap);
    let distributor = type_name::with_defining_ids<Distributor>();
    if (!self.distributors.contains(&distributor)) {
        self.distributors.insert(distributor);
        emit(DistributorAuthorized {
            pressing_id: self.id.to_inner(),
            distributor,
        });
    };
}

/// Revoke distributor witness type `Distributor` for this edition.
/// Revoking a missing distributor is a no-op.
public fun revoke_distributor<Distributor: drop>(
    self: &mut Pressing,
    cap: &PressingAdminCap,
) {
    self.authorize(cap);
    let distributor = type_name::with_defining_ids<Distributor>();
    if (self.distributors.contains(&distributor)) {
        self.distributors.remove(&distributor);
        emit(DistributorRevoked {
            pressing_id: self.id.to_inner(),
            distributor,
        });
    };
}

/// Mint the next Record by consuming an authorized distributor witness.
///
/// The Record number is allocated here and cannot be selected by the caller.
/// The returned Record remains composable: the distributor decides whether to
/// transfer, wrap, freeze, or otherwise deliver it.
public fun mint<Distributor: drop>(
    self: &mut Pressing,
    _distributor: Distributor,
    clock: &Clock,
): Record {
    self.assert_version();
    assert!(self.is_distributor_authorized<Distributor>(), EDistributorNotAuthorized);
    self.max_supply.do_ref!(|max| assert!(self.supply < *max, EMaxSupplyReached));

    self.supply = self.supply + 1;
    record::new<Distributor>(
        &mut self.id,
        self.release_id,
        self.edition,
        self.supply,
        clock,
    )
}

//=== Extension Access ===

public fun uid(self: &Pressing): &UID {
    &self.id
}

/// Mutably access the Pressing UID for cap-authorized extensions, including
/// distributor-owned objects derived from this edition.
public fun uid_mut(self: &mut Pressing, cap: &PressingAdminCap): &mut UID {
    self.authorize(cap);
    &mut self.id
}

//=== View Functions ===

public fun release_id(self: &Pressing): ID {
    self.release_id
}

public fun version(self: &Pressing): u64 {
    self.version
}

public fun edition(self: &Pressing): u64 {
    self.edition
}

public fun supply(self: &Pressing): u64 {
    self.supply
}

public fun max_supply(self: &Pressing): Option<u64> {
    self.max_supply
}

public fun distributors(self: &Pressing): &vector<TypeName> {
    self.distributors.keys()
}

public fun is_distributor_authorized<Distributor: drop>(self: &Pressing): bool {
    self.distributors.contains(&type_name::with_defining_ids<Distributor>())
}

public fun pressing_id(cap: &PressingAdminCap): ID {
    cap.pressing_id
}

/// Derive an edition's Pressing ID from its Release ID.
public fun derive_id(release_id: ID, edition: u64): ID {
    derived_object::derive_address(release_id, PressingKey(edition)).to_id()
}

/// Derive a Pressing's admin capability ID.
public fun derive_admin_cap_id(pressing_id: ID): ID {
    derived_object::derive_address(pressing_id, PressingAdminCapKey()).to_id()
}

//=== Internal Functions ===

fun authorize(self: &Pressing, cap: &PressingAdminCap) {
    self.assert_version();
    assert!(cap.pressing_id == self.id.to_inner(), EUnauthorized);
}

fun assert_version(self: &Pressing) {
    assert!(self.version == VERSION, EWrongVersion);
}

//=== Test Helpers ===

#[test_only]
public fun new_for_testing(
    release_id: ID,
    edition: u64,
    max_supply: Option<u64>,
    ctx: &mut TxContext,
): (Pressing, PressingAdminCap) {
    assert!(edition > 0, EInvalidEdition);
    max_supply.do_ref!(|max| assert!(*max > 0, EInvalidMaxSupply));

    let mut id = object::new(ctx);
    let pressing_id = id.to_inner();
    let admin_cap = PressingAdminCap {
        id: derived_object::claim(&mut id, PressingAdminCapKey()),
        pressing_id,
    };
    (
        Pressing {
            id,
            version: VERSION,
            release_id,
            edition,
            supply: 0,
            max_supply,
            distributors: vec_set::empty(),
        },
        admin_cap,
    )
}


#[test_only]
public fun set_version_for_testing(self: &mut Pressing, version: u64) {
    self.version = version;
}

#[test_only]
public fun foreign_admin_cap_for_testing(
    pressing_id: ID,
    ctx: &mut TxContext,
): PressingAdminCap {
    PressingAdminCap { id: object::new(ctx), pressing_id }
}

#[test_only]
public fun created_event_fields(event: PressingCreated): (ID, ID, u64, Option<u64>) {
    let PressingCreated { pressing_id, release_id, edition, max_supply } = event;
    (pressing_id, release_id, edition, max_supply)
}

#[test_only]
public fun distributor_authorized_event_fields(
    event: DistributorAuthorized,
): (ID, TypeName) {
    let DistributorAuthorized { pressing_id, distributor } = event;
    (pressing_id, distributor)
}

#[test_only]
public fun distributor_revoked_event_fields(event: DistributorRevoked): (ID, TypeName) {
    let DistributorRevoked { pressing_id, distributor } = event;
    (pressing_id, distributor)
}
