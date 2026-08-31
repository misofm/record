// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The Miso record — an owned, ownable copy of a release.
///
/// A record's universal fact is the release it copies. Everything about the way a
/// particular copy came to exist belongs to its embedded, issuer-defined
/// `Certificate`: its type identifies the issuance path, and its value carries that
/// path's immutable facts. This keeps the core independent of sale mechanics without
/// a mutable issuer registry. An arbitrary package can mint `Record<TheirCertificate>`
/// but cannot mint a trusted specialization unless it can construct that certificate.
/// A trusted certificate type must restrict construction and omit `copy`; the core's
/// `drop + store` bound permits both trusted and deliberately permissionless designs.
///
/// Extensions may still attach contextual state to the record UID. The certificate is
/// different: it is a private field, created with the record and never detachable.
/// `Record` is key-only: this module exposes address transfer, but deliberately exposes
/// no share or freeze path and cannot be bypassed with the framework's `public_*` APIs.
module miso_record::record;

use sui::derived_object;
use sui::event::emit;

//=== Structs ===

public struct Record<Certificate: drop + store> has key {
    id: UID,
    /// The release this is a copy of. This is the sole universal record fact.
    release_id: ID,
    /// Immutable, issuer-defined context. Its provenance is meaningful to consumers
    /// that trust this concrete certificate type.
    certificate: Certificate,
}

/// Key for deriving a record UID off its minting parent. The issuer defines the
/// number's semantics. Move 2024 requires the type to be public, but its positional
/// field is module-private, so only this module can construct a key.
public struct RecordKey(u64) has copy, drop, store;

//=== Events ===

/// The certificate type is carried in the event type, making trusted issuance paths
/// directly filterable without a runtime allowlist.
public struct RecordCreatedEvent<phantom Certificate> has copy, drop {
    record_id: ID,
    parent_id: ID,
    release_id: ID,
    number: u64,
}

/// A record was destroyed. Like creation, the certificate type stays in the event
/// type so untrusted record specializations cannot pollute a trusted event stream.
public struct RecordDestroyedEvent<phantom Certificate> has copy, drop {
    record_id: ID,
    release_id: ID,
}

//=== Public Functions ===

/// Create a record with an issuer-defined `certificate`. The certificate is embedded
/// permanently, so a caller that can construct a private certificate type controls
/// minting of that exact `Record<Certificate>` specialization.
public fun new<Certificate: drop + store>(
    parent: &mut UID,
    certificate: Certificate,
    release_id: ID,
    number: u64,
): Record<Certificate> {
    let parent_id = parent.to_inner();
    let record = Record {
        id: derived_object::claim(parent, RecordKey(number)),
        release_id,
        certificate,
    };
    emit(RecordCreatedEvent<Certificate> {
        record_id: object::id(&record),
        parent_id,
        release_id,
        number,
    });
    record
}

/// Transfer a record to `recipient`.
///
/// `Record` deliberately omits `store`, so this module-restricted transfer is the
/// only address-transfer path. In particular, external packages cannot publicly
/// share, freeze, wrap, or transfer a record around this API.
public fun transfer<Certificate: drop + store>(
    record: Record<Certificate>,
    recipient: address,
) {
    transfer::transfer(record, recipient)
}

/// Destroy a record. The caller is responsible for detaching any optional dynamic
/// field extensions first; the embedded certificate is destroyed with the record.
public fun destroy<Certificate: drop + store>(self: Record<Certificate>) {
    let record_id = object::id(&self);
    let Record { id, release_id, .. } = self;
    id.delete();
    emit(RecordDestroyedEvent<Certificate> { record_id, release_id });
}

//=== Extension access (possession is authority) ===

public fun uid<Certificate: drop + store>(self: &Record<Certificate>): &UID {
    &self.id
}

public fun uid_mut<Certificate: drop + store>(self: &mut Record<Certificate>): &mut UID {
    &mut self.id
}

//=== View Functions ===

public fun release_id<Certificate: drop + store>(self: &Record<Certificate>): ID {
    self.release_id
}

/// Read the immutable issuer-defined certificate.
public fun certificate<Certificate: drop + store>(self: &Record<Certificate>): &Certificate {
    &self.certificate
}

public fun derive_address(parent: ID, number: u64): address {
    derived_object::derive_address(parent, RecordKey(number))
}

//=== Test Helpers ===

#[test_only]
public fun record_created_event_fields<Certificate>(
    event: RecordCreatedEvent<Certificate>,
): (ID, ID, ID, u64) {
    let RecordCreatedEvent { record_id, parent_id, release_id, number } = event;
    (record_id, parent_id, release_id, number)
}

#[test_only]
public fun record_destroyed_event_fields<Certificate>(
    event: RecordDestroyedEvent<Certificate>,
): (ID, ID) {
    let RecordDestroyedEvent { record_id, release_id } = event;
    (record_id, release_id)
}
