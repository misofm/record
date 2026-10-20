# miso-record

The Miso Record package owns the complete Record lifecycle on Sui. A `Pressing` is
one numbered edition of a Miso Release; a `Record` is one numbered purchase within
that edition. External Distributor packages validate different sales mechanics.

```move
public struct Pressing has key {
    id: UID,
    release_id: ID,
    edition: u16,
    supply: u32,
    max_supply: u32,
    distributors: VecSet<TypeName>,
}

public struct Record has key, store {
    id: UID,
    release_id: ID,
    pressing_id: ID,
    edition: u16,
    number: u32,
    purchase_currency: TypeName,
    purchase_price: u64,
    purchased_at_ms: u64,
}
```

There is no singleton Registry, Table, Settings object, or package initializer.
Unrelated editions mutate unrelated Pressings and can sell concurrently.

The package is intended to be made immutable when published. Future lifecycle
designs ship as separate packages with explicit migration paths, so on-chain
objects do not carry package-upgrade versions.

## Deterministic editions and Records

Each Pressing is derived directly from its Release at `PressingKey(edition)`. The
Release's `ReleaseAdminCap` authorizes creation, and claiming the same edition twice
aborts. Editions must be created sequentially, starting at 1: for edition `n > 1`,
the Release must already contain the derived claim for edition `n - 1`. This does
not require that the previous edition has sold out or been shared.

```move
let (mut pressing, pressing_cap) = pressing::new(
    release,
    release_cap,
    1,
    500,
);
```

Edition numbers are `u16` values from 1 through 65,535. Record numbers are `u32`
values starting at 1. Every Pressing owns an independent
Record sequence, so Edition 1 Record 1 and Edition 2 Record 1 are both valid and have
different IDs.

```move
let pressing_address = pressing::derive_address(release_id, edition);
let record_address = record::derive_address(pressing_id, number);
```

The full identity chain is therefore:

```text
Release
└── PressingKey(edition) → Pressing
    └── RecordKey(number) → Record
```

## Supply

`max_supply` is a required positive `u32`, fixed when the Pressing is created. It
caps lifetime issuance across all distributors and currencies. Destroying a Record
does not restore capacity. Further issuance beyond the cap requires a new
edition.

The Pressing checks the cap before incrementing `supply`. Failed or unauthorized
presses do not consume a number because the transaction rolls back atomically.

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
public fun purchase<Currency>(
    pressing: &mut Pressing,
    purchase_price: u64,
    clock: &Clock,
): Record {
    pressing.press<DistributorWitness, Currency>(
        DistributorWitness(),
        purchase_price,
        clock,
    )
}
```

`press` returns the Record rather than transferring it. The Distributor remains free
to deliver it through any composable transaction flow. The Distributor validates
payment and sale state; `record` stores the resulting purchase provenance.

The `Distributor` and `Currency` types are carried by the concrete
`pressing::RecordPurchasedEvent<Distributor, Currency>` event type. They are
not duplicated as serialized strings in that payload; `Currency` remains part
of the Record's stored purchase provenance.

## Stored lifecycle data

The package derives or stamps every Record field:

- `release_id`, `pressing_id`, and `edition` come from the Pressing.
- `number` is allocated from the Pressing's edition-local sequence.
- The Record UID is claimed at `RecordKey(number)` from the Pressing UID.
- `purchase_currency` comes from the Distributor's concrete `Currency` type.
- `purchase_price` is the amount validated by the Distributor; 0 is a free Record.
- `purchased_at_ms` comes from Sui's `Clock`.

Neither the buyer nor the eventual recipient is stored: the returned Record
remains composable and may be purchased as a gift, so its current owner is the
only holder that matters on-chain. Indexers that need the buyer can read the
transaction sender of the `RecordPurchasedEvent`.

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

| Event | Fields |
|---|---|
| `PressingCreatedEvent` | `pressing_id`, `release_id`, `edition`, `max_supply` |
| `PressingDistributorAuthorizedEvent<Distributor>` | `pressing_id` |
| `PressingDistributorRevokedEvent<Distributor>` | `pressing_id` |
| `RecordPurchasedEvent<Distributor, Currency>` | `record_id`, `pressing_id`, `number`, `purchase_price` |
| `RecordDestroyedEvent` | `record_id` |

All IDs are `ID`. Distributor and Currency are phantom type parameters on the
event type. Sharing is silent, and distributor events fire only when the set
changes. Other facts are derivable: the buyer is the transaction's sender,
and release and edition join from `PressingCreatedEvent` by `pressing_id`.
Destruction joins to `RecordPurchasedEvent` by `record_id`.

## Layout

```text
Move.toml
sources/
  pressing.move
  record.move
tests/
  pressing_event_tests.move
  record_tests.move
```

## Build

```bash
sui move test -e testnet
```

## License

[Functional Source License 1.1, ALv2 Future License](./LICENSE.md)
(FSL-1.1-ALv2). Any use except a Competing Use is permitted, and each version
becomes Apache-2.0 two years after its release.
