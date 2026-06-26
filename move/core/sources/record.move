// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The Miso record — an owned, ownable copy of a release.
///
/// Deliberately slim, like `miso_player`: a `Record` is just an id, the release it
/// is a copy of, and its number. It is an owned object, and everything else —
/// pressing/edition logic, settings, statistics, vouchers — is added by extensions
/// that attach to the record's `UID` via dynamic fields. The release is referenced
/// by `ID` only, so the core has no dependency on the protocol; extensions that need
/// the typed `Release` bring that dependency themselves.
///
/// Authority is possession: only the owner can produce a `&mut Record`, so `uid_mut`
/// is fully open — no capability, no allowlist. Minting policy (who may press which
/// release, and how `number` is assigned) is an extension concern, not the core's.
module miso_record::record;

use sui::event::emit;

//=== Structs ===

public struct Record has key, store {
    id: UID,
    release_id: ID,
    number: u32,
}

//=== Events ===

public struct RecordCreatedEvent has copy, drop {
    record_id: ID,
    release_id: ID,
    number: u32,
    created_by: address,
}

public struct RecordDestroyedEvent has copy, drop {
    record_id: ID,
    release_id: ID,
    number: u32,
}

//=== Public Functions ===

/// Mint a record of `release_id` with the given `number`. The caller (a pressing
/// extension) owns the numbering/authority policy.
public fun new(release_id: ID, number: u32, ctx: &mut TxContext): Record {
    let record = Record { id: object::new(ctx), release_id, number };

    emit(RecordCreatedEvent {
        record_id: record.id(),
        release_id,
        number,
        created_by: ctx.sender(),
    });

    record
}

/// Destroy a record. The caller is responsible for detaching any extensions first;
/// dynamic fields left attached become unreachable.
public fun destroy(self: Record) {
    let record_id = self.id();
    let Record { id, release_id, number } = self;
    id.delete();
    emit(RecordDestroyedEvent { record_id, release_id, number });
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

public fun number(self: &Record): u32 {
    self.number
}
