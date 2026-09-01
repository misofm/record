# miso-record

The Miso Record package owns the complete Record lifecycle on Sui. A `Pressing` is
one numbered edition of a Miso Release; a `Record` is one
numbered copy within that edition. External Distributor packages decide how a Record
is sold, redeemed, airdropped, migrated, or otherwise delivered.

```move
public struct Pressing has key {
    id: UID,
    version: u64,
    release_id: ID,
    edition: u64,
    supply: u64,
    max_supply: Option<u64>,
    distributors: VecSet<TypeName>,
}

public struct Record has key, store {
    id: UID,
    release_id: ID,
    pressing_id: ID,
    edition: u64,
    number: u64,
    created_at_ms: u64,
}
```

There is no singleton Registry, Table, Settings object, or package initializer.
Unrelated editions mutate unrelated Pressings and can mint concurrently.

Pressings currently use representation version `1`. Minting, Distributor
authorization/revocation, and cap-gated mutable UID access reject unsupported
versions so package upgrades fail closed until an explicit migration exists.

## Deterministic editions and Records

Each Pressing is derived directly from its Release at `PressingKey(edition)`. The
Release's `ReleaseAdminCap` authorizes creation, and claiming the same edition twice
aborts:

```move
let (mut pressing, pressing_cap) = pressing::new(
    release,
    release_cap,
    1,
    option::some(500),
);
```

Edition numbers and Record numbers are 1-based. Every Pressing owns an independent
Record sequence, so Edition 1 Record 1 and Edition 2 Record 1 are both valid and have
different IDs.

```move
let pressing_id = pressing::derive_id(release_id, edition);
let record_id = record::derive_id(pressing_id, number);
```

The full identity chain is therefore:

```text
Release
└── PressingKey(edition) → Pressing
    └── RecordKey(number) → Record
```

## Supply

`max_supply` is fixed when the Pressing is created:

- `none()` creates an unlimited edition.
- `some(quantity)` creates a permanently capped edition.
- `some(0)` is invalid.

The Pressing checks the cap before incrementing `supply`. Failed or unauthorized
mints do not consume a number because the transaction rolls back atomically.

## Distributors

Each Pressing authorizes its own small set of module-controlled Distributor witness
types. This permits concurrent distribution paths and edition-specific policy without
a global governance object:

```move
pressing.authorize_distributor<record_store::DistributorWitness>(&pressing_cap);
pressing.revoke_distributor<legacy_store::DistributorWitness>(&pressing_cap);
```

Both operations are idempotent and emit an event only when the set changes. A new
Distributor can be authorized before the old one is revoked, preserving the edition's
existing sequence during migration.

A Distributor constructs its witness internally and consumes it immediately:

```move
public fun distribute(
    pressing: &mut Pressing,
    clock: &Clock,
): Record {
    pressing.mint(DistributorWitness(), clock)
}
```

`mint` returns the Record rather than transferring it. The Distributor remains free
to deliver it through any composable transaction flow. Prices, payments, schedules,
recipient selection, and sale state do not belong in `miso_record`.

The witness type is written to `RecordCreated` for audit and indexing but is not
stored on every Record.

## Stored lifecycle data

The package derives or stamps every Record field:

- `release_id`, `pressing_id`, and `edition` come from the Pressing.
- `number` is allocated from the Pressing's edition-local sequence.
- The Record UID is claimed at `RecordKey(number)` from the Pressing UID.
- `created_at_ms` comes from Sui's `Clock`.

Purchase currency, payer, price, and recipient are Distributor concerns rather than
universal Record lifecycle data.

## Ownership and extensions

`Record` has `key + store`, so callers use Sui's framework ownership operations
directly:

```move
transfer::public_transfer(record, recipient);
```

Records may also be wrapped, placed in compatible custody systems, shared, or frozen.
The Record module intentionally provides no redundant transfer wrapper and does not
enforce direct address ownership.

Consequently, an immutable `&Record` is not by itself proof that the transaction
sender owns it: shared and frozen Records are readable by non-owners. Any
ownership-gated policy must establish the relevant ownership mode independently.

Extensions may use mutable Record access:

```move
public fun uid(self: &Record): &UID
public fun uid_mut(self: &mut Record): &mut UID
```

Callers must detach extensions before destroying a Record or those dynamic fields
become inaccessible.

## Events

| Event | Facts |
|---|---|
| `PressingCreated` | Pressing, release, edition, and optional maximum supply |
| `DistributorAuthorized` | Pressing and authorized Distributor type |
| `DistributorRevoked` | Pressing and revoked Distributor type |
| `RecordCreated` | Record lineage, edition-local number, creation time, and Distributor type |
| `RecordDestroyed` | Record and its Pressing |

## Layout

```text
Move.toml
sources/
  pressing.move
  record.move
tests/
  record_tests.move
```

## Build

```bash
sui move test
```

This architecture changes the Record layout and mint API, adds Pressing, and removes
Registry and Settings. It therefore requires a fresh publication. Distributor,
Seal-policy, SDK, and application consumers must migrate to Pressing IDs and
edition-local Record numbers.

License: Apache-2.0
