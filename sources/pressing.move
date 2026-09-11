// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One edition of a Miso release and the complete lifecycle boundary for its
/// Records.
///
/// A release may have many Pressings, one at each `PressingKey(edition)`. Each
/// Pressing owns an independent Record sequence, an optional immutable
/// maximum supply, and the set of distributor witness types allowed to mint from
/// that edition. Distributors own delivery mechanics; the Pressing owns issuance.
module record::pressing;

use musicos::release::{Release, ReleaseAdminCap};
use record::record::{Self, Record};
use std::ascii::String;
use std::type_name::{Self, TypeName};
use sui::{clock::Clock, derived_object, event::emit, vec_set::{Self, VecSet}};

// === Structs ===

/// Key for deriving one edition's Pressing from its Release.
public struct PressingKey(u16) has copy, drop, store;

/// Key for deriving the capability that administers a Pressing.
public struct PressingAdminCapKey() has copy, drop, store;

/// One edition's Record namespace, supply, cap, and authorized distributors.
public struct Pressing has key {
    /// The Pressing's derived object identity.
    id: UID,
    /// The parent release represented by this edition.
    release_id: ID,
    /// The edition number.
    edition: u16,
    /// The number of Records issued by this Pressing.
    supply: u32,
    /// The immutable supply ceiling, or `none()` for an uncapped Pressing.
    max_supply: Option<u32>,
    /// The defining types of distributors currently permitted to mint.
    distributors: VecSet<TypeName>,
}

/// Authority to add or remove distributors and extend a specific Pressing.
public struct PressingAdminCap has key, store {
    /// The capability's derived object identity.
    id: UID,
    /// The Pressing controlled by this capability.
    pressing_id: ID,
}

// === Events ===

/// Emitted when an artist creates a Pressing for a release edition.
///
/// The payload is a complete snapshot of the newly-created Pressing and both
/// capabilities involved in deriving it. `distributors` is represented as
/// defining type names so an indexer does not need to fetch the object to
/// reconstruct its initial configuration.
public struct PressingCreatedEvent has copy, drop {
    /// The newly created Pressing.
    pressing_id: address,
    /// The parent release.
    release_id: address,
    /// The Pressing's admin capability.
    pressing_admin_cap_id: address,
    /// The Release admin capability used to create this Pressing.
    release_admin_cap_id: address,
    /// The Pressing's edition number.
    edition: u16,
    /// The number of Records issued by this Pressing.
    supply: u32,
    /// The immutable supply ceiling, if one exists.
    max_supply: Option<u32>,
    /// Defining type names of distributors currently permitted to mint.
    distributors: vector<String>,
}

/// Legacy event declaration retained for source compatibility. New code should
/// consume `PressingDistributorAuthorizedEvent`.
public struct DistributorAuthorizedEvent has copy, drop {
    /// The configured Pressing.
    pressing_id: ID,
    /// The authorized distributor's defining type.
    distributor: TypeName,
}

/// Legacy event declaration retained for source compatibility. New code should
/// consume `PressingDistributorRevokedEvent`.
public struct DistributorRevokedEvent has copy, drop {
    /// The configured Pressing.
    pressing_id: ID,
    /// The revoked distributor's defining type.
    distributor: TypeName,
}

/// Emitted after a Pressing mints a Record for an authorized distributor.
public struct RecordPurchasedEvent<phantom Distributor: drop, phantom Currency> has copy, drop {
    /// The purchased Record.
    record_id: address,
    /// The release represented by the Record.
    release_id: address,
    /// The Pressing that issued the Record.
    pressing_id: address,
    /// The edition represented by the Pressing.
    edition: u16,
    /// The Record's number within its edition.
    number: u32,
    /// The defining type of the purchase currency.
    purchase_currency: String,
    /// The amount paid for the Record.
    purchase_price: u64,
    /// The transaction sender who purchased the Record.
    purchased_by: address,
    /// The purchase time in Unix milliseconds from Sui's Clock.
    purchased_timestamp_ms: u64,
    /// The defining type of the distributor that authorized the mint.
    distributor: String,
    /// Supply immediately before this mint.
    supply_before: u32,
    /// Supply delta applied by this mint.
    supply_delta: u32,
    /// Supply immediately after this mint.
    supply_after: u32,
    /// The immutable supply ceiling, if one exists.
    max_supply: Option<u32>,
}

/// Emitted after a Pressing is shared, with a complete post-configuration
/// snapshot captured before ownership is consumed by the framework.
public struct PressingSharedEvent has copy, drop {
    pressing_id: address,
    release_id: address,
    edition: u16,
    supply: u32,
    max_supply: Option<u32>,
    distributors: vector<String>,
}

/// Emitted when a distributor witness type is newly authorized for an edition.
public struct PressingDistributorAuthorizedEvent<phantom Distributor: drop> has copy, drop {
    pressing_id: address,
    release_id: address,
    edition: u16,
    pressing_admin_cap_id: address,
    distributor: String,
    authorized_before: bool,
    authorized_after: bool,
    distributor_count_before: u64,
    distributor_count_after: u64,
}

/// Emitted when a distributor witness type is removed from an edition.
public struct PressingDistributorRevokedEvent<phantom Distributor: drop> has copy, drop {
    pressing_id: address,
    release_id: address,
    edition: u16,
    pressing_admin_cap_id: address,
    distributor: String,
    authorized_before: bool,
    authorized_after: bool,
    distributor_count_before: u64,
    distributor_count_after: u64,
}

// === Errors ===

const EUnauthorized: u64 = 0;
const EInvalidEdition: u64 = 1;
const EInvalidMaxSupply: u64 = 2;
const EDistributorNotAuthorized: u64 = 3;
const EMaxSupplyReached: u64 = 4;
const EInvalidPurchasePrice: u64 = 5;

// === Public Functions ===

/// Create one edition's Pressing under its Release.
///
/// `max_supply = none()` creates an uncapped edition; `some(quantity)` creates a
/// permanently capped edition. The Pressing and its
/// admin capability are returned for composition before the caller shares the
/// Pressing and custodies the capability.
public fun new(
    release: &mut Release,
    release_cap: &ReleaseAdminCap,
    edition: u16,
    max_supply: Option<u32>,
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

    let pressing = Pressing {
        id,
        release_id,
        edition,
        supply: 0,
        max_supply,
        distributors: vec_set::empty(),
    };

    emit(PressingCreatedEvent {
        pressing_id: pressing_id.to_address(),
        release_id: release_id.to_address(),
        pressing_admin_cap_id: object::id_address(&admin_cap),
        release_admin_cap_id: object::id_address(release_cap),
        edition: pressing.edition,
        supply: pressing.supply,
        max_supply: pressing.max_supply,
        distributors: distributor_names(&pressing),
    });

    (pressing, admin_cap)
}

/// Share a newly created Pressing after configuring its distributors.
public fun share(self: Pressing) {
    let pressing_id = object::id(&self).to_address();
    let release_id = self.release_id.to_address();
    let edition = self.edition;
    let supply = self.supply;
    let max_supply = self.max_supply;
    let distributors = distributor_names(&self);

    transfer::share_object(self);

    emit(PressingSharedEvent {
        pressing_id,
        release_id,
        edition,
        supply,
        max_supply,
        distributors,
    });
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
        let pressing_id = self.id.to_inner().to_address();
        let release_id = self.release_id.to_address();
        let edition = self.edition;
        let pressing_admin_cap_id = object::id_address(cap);
        let distributor_name = distributor.into_string();
        let distributor_count_before = self.distributors.length();
        let authorized_before = false;
        self.distributors.insert(distributor);
        emit(PressingDistributorAuthorizedEvent<Distributor> {
            pressing_id,
            release_id,
            edition,
            pressing_admin_cap_id,
            distributor: distributor_name,
            authorized_before,
            authorized_after: true,
            distributor_count_before,
            distributor_count_after: self.distributors.length(),
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
        let pressing_id = self.id.to_inner().to_address();
        let release_id = self.release_id.to_address();
        let edition = self.edition;
        let pressing_admin_cap_id = object::id_address(cap);
        let distributor_name = distributor.into_string();
        let distributor_count_before = self.distributors.length();
        let authorized_before = true;
        self.distributors.remove(&distributor);
        emit(PressingDistributorRevokedEvent<Distributor> {
            pressing_id,
            release_id,
            edition,
            pressing_admin_cap_id,
            distributor: distributor_name,
            authorized_before,
            authorized_after: false,
            distributor_count_before,
            distributor_count_after: self.distributors.length(),
        });
    };
}

/// Purchase the next Record by consuming an authorized distributor witness.
///
/// The Record number is allocated here and cannot be selected by the caller.
/// The returned Record remains composable: the distributor decides whether to
/// transfer, wrap, freeze, or otherwise deliver it.
public fun mint<Distributor: drop, Currency>(
    self: &mut Pressing,
    _distributor: Distributor,
    purchase_price: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Record {
    assert!(self.is_distributor_authorized<Distributor>(), EDistributorNotAuthorized);
    assert!(purchase_price > 0, EInvalidPurchasePrice);
    self.max_supply.do_ref!(|max| assert!(self.supply < *max, EMaxSupplyReached));

    let supply_before = self.supply;
    let max_supply = self.max_supply;
    self.supply = self.supply + 1;
    let purchased = record::new<Currency>(
        &mut self.id,
        self.release_id,
        self.edition,
        self.supply,
        purchase_price,
        clock,
        ctx,
    );
    emit(RecordPurchasedEvent<Distributor, Currency> {
        record_id: object::id(&purchased).to_address(),
        release_id: purchased.release_id().to_address(),
        pressing_id: purchased.pressing_id().to_address(),
        edition: purchased.edition(),
        number: purchased.number(),
        purchase_currency: purchased.purchase_currency().into_string(),
        purchase_price: purchased.purchase_price(),
        purchased_by: purchased.purchased_by(),
        purchased_timestamp_ms: purchased.purchased_timestamp_ms(),
        distributor: type_name::with_defining_ids<Distributor>().into_string(),
        supply_before,
        supply_delta: 1,
        supply_after: self.supply,
        max_supply,
    });
    purchased
}

// === Extension Access ===

/// Borrow the Pressing UID for read-only extensions.
public fun uid(self: &Pressing): &UID {
    &self.id
}

/// Mutably access the Pressing UID for cap-authorized extensions, including
/// distributor-owned objects derived from this edition.
public fun uid_mut(self: &mut Pressing, cap: &PressingAdminCap): &mut UID {
    self.authorize(cap);
    &mut self.id
}

// === View Functions ===

/// Return the release represented by this Pressing.
public fun release_id(self: &Pressing): ID {
    self.release_id
}

/// Return this Pressing's edition number.
public fun edition(self: &Pressing): u16 {
    self.edition
}

/// Return the number of Records issued by this Pressing.
public fun supply(self: &Pressing): u32 {
    self.supply
}

/// Return the immutable supply ceiling, if one exists.
public fun max_supply(self: &Pressing): Option<u32> {
    self.max_supply
}

/// Borrow the defining types of all currently authorized distributors.
public fun distributors(self: &Pressing): &vector<TypeName> {
    self.distributors.keys()
}

/// Return whether `Distributor` is currently authorized to mint.
public fun is_distributor_authorized<Distributor: drop>(self: &Pressing): bool {
    self.distributors.contains(&type_name::with_defining_ids<Distributor>())
}

/// Return the Pressing controlled by this capability.
public fun pressing_id(cap: &PressingAdminCap): ID {
    cap.pressing_id
}

/// Derive an edition's Pressing address from its Release ID.
public fun derive_address(release_id: ID, edition: u16): address {
    derived_object::derive_address(release_id, PressingKey(edition))
}

/// Derive a Pressing's admin capability address.
public fun derive_admin_cap_address(pressing_id: ID): address {
    derived_object::derive_address(pressing_id, PressingAdminCapKey())
}

// === Private Functions ===

/// Convert the current distributor set into its defining type-name strings in
/// VecSet insertion order. Event payloads use strings so they remain directly
/// indexable without requiring a TypeName decoder.
fun distributor_names(self: &Pressing): vector<String> {
    let mut names = vector[];
    self.distributors.keys().do_ref!(|distributor| names.push_back((*distributor).into_string()));
    names
}

fun authorize(self: &Pressing, cap: &PressingAdminCap) {
    assert!(cap.pressing_id == self.id.to_inner(), EUnauthorized);
}

// === Test Functions ===

#[test_only]
public fun new_for_testing(
    release_id: ID,
    edition: u16,
    max_supply: Option<u32>,
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
public fun foreign_admin_cap_for_testing(
    pressing_id: ID,
    ctx: &mut TxContext,
): PressingAdminCap {
    PressingAdminCap { id: object::new(ctx), pressing_id }
}

#[test_only]
public fun created_event_fields(
    event: PressingCreatedEvent,
): (address, address, address, address, u16, u32, Option<u32>, vector<String>) {
    let PressingCreatedEvent {
        pressing_id,
        release_id,
        pressing_admin_cap_id,
        release_admin_cap_id,
        edition,
        supply,
        max_supply,
        distributors,
    } = event;
    (
        pressing_id,
        release_id,
        pressing_admin_cap_id,
        release_admin_cap_id,
        edition,
        supply,
        max_supply,
        distributors,
    )
}

#[test_only]
public fun distributor_authorized_event_fields(
    event: DistributorAuthorizedEvent,
): (ID, TypeName) {
    let DistributorAuthorizedEvent { pressing_id, distributor } = event;
    (pressing_id, distributor)
}

#[test_only]
public fun distributor_revoked_event_fields(event: DistributorRevokedEvent): (ID, TypeName) {
    let DistributorRevokedEvent { pressing_id, distributor } = event;
    (pressing_id, distributor)
}

#[test_only]
public fun shared_event_fields(
    event: PressingSharedEvent,
): (address, address, u16, u32, Option<u32>, vector<String>) {
    let PressingSharedEvent {
        pressing_id,
        release_id,
        edition,
        supply,
        max_supply,
        distributors,
    } = event;
    (pressing_id, release_id, edition, supply, max_supply, distributors)
}

#[test_only]
public fun pressing_distributor_authorized_event_fields<Distributor: drop>(
    event: PressingDistributorAuthorizedEvent<Distributor>,
): (address, address, u16, address, String, bool, bool, u64, u64) {
    let PressingDistributorAuthorizedEvent {
        pressing_id,
        release_id,
        edition,
        pressing_admin_cap_id,
        distributor,
        authorized_before,
        authorized_after,
        distributor_count_before,
        distributor_count_after,
    } = event;
    (
        pressing_id,
        release_id,
        edition,
        pressing_admin_cap_id,
        distributor,
        authorized_before,
        authorized_after,
        distributor_count_before,
        distributor_count_after,
    )
}

#[test_only]
public fun pressing_distributor_revoked_event_fields<Distributor: drop>(
    event: PressingDistributorRevokedEvent<Distributor>,
): (address, address, u16, address, String, bool, bool, u64, u64) {
    let PressingDistributorRevokedEvent {
        pressing_id,
        release_id,
        edition,
        pressing_admin_cap_id,
        distributor,
        authorized_before,
        authorized_after,
        distributor_count_before,
        distributor_count_after,
    } = event;
    (
        pressing_id,
        release_id,
        edition,
        pressing_admin_cap_id,
        distributor,
        authorized_before,
        authorized_after,
        distributor_count_before,
        distributor_count_after,
    )
}

/// Short aliases for the rich Distributor transition accessors. The longer
/// names above make the event family explicit; these aliases keep test callers
/// ergonomic while remaining test-only API.
#[test_only]
public fun authorized_event_fields<Distributor: drop>(
    event: PressingDistributorAuthorizedEvent<Distributor>,
): (address, address, u16, address, String, bool, bool, u64, u64) {
    pressing_distributor_authorized_event_fields(event)
}

#[test_only]
public fun revoked_event_fields<Distributor: drop>(
    event: PressingDistributorRevokedEvent<Distributor>,
): (address, address, u16, address, String, bool, bool, u64, u64) {
    pressing_distributor_revoked_event_fields(event)
}

#[test_only]
public fun purchased_event_fields<Distributor: drop, Currency>(
    event: RecordPurchasedEvent<Distributor, Currency>,
): (address, address, address, u16, u32, String, u64, address, u64, String, u32, u32, u32, Option<u32>) {
    let RecordPurchasedEvent {
        record_id,
        release_id,
        pressing_id,
        edition,
        number,
        purchase_currency,
        purchase_price,
        purchased_by,
        purchased_timestamp_ms,
        distributor,
        supply_before,
        supply_delta,
        supply_after,
        max_supply,
    } = event;
    (
        record_id,
        release_id,
        pressing_id,
        edition,
        number,
        purchase_currency,
        purchase_price,
        purchased_by,
        purchased_timestamp_ms,
        distributor,
        supply_before,
        supply_delta,
        supply_after,
        max_supply,
    )
}
