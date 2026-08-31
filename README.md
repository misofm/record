# miso-record

The Miso Record is an owned copy of a release on Sui. It is Miso's concrete
distribution format: one stable Registry defines Record identity and per-release
numbering while one governance-selected sales implementation controls creation.

```move
public struct Record has key, store {
    id: UID,
    release_id: ID,
    registry_id: ID,
    number: u64,
    created_at_ms: u64,
    purchase_currency: TypeName,
    purchased_by: address,
}
```

There is one concrete Record type. Its immutable birth and purchase provenance is
stored directly rather than delegated to a generic certificate.

## Canonical Registry

`RecordRegistry` is the singleton parent and canonical per-release number store:

```move
public struct RecordRegistry has key {
    id: UID,
    supplies: Table<ID, u64>,
}
```

The Registry is created and shared during package publication. Every successful mint
increments the named release's supply, uses that value as the Record's `number`,
and claims `RecordKey(release_id, number)` from the Registry UID. A Record's
address is therefore stable across complete replacements of the sales package:

```move
let expected = record::derive_address(registry_id, release_id, number);
```

Each release gets its own `1, 2, 3…` sequence, while `release_id` in the key keeps
equal numbers collision-free. The Registry is intentionally a mutable shared input to
every mint. Transactions still serialize on that root even though supplies live in a
`Table`, which is the accepted cost of preserving canonical numbering across sales
implementations.

## Creation policy

`miso_record::settings::Settings` holds exactly one active witness type:

```move
public struct Settings has key {
    id: UID,
    witness: Option<TypeName>,
}
```

The admin can atomically replace the complete sales implementation or disable Record
creation:

```move
settings.set_witness<miso_pressing::pressing::MintWitness>(&settings_admin_cap);
settings.clear_witness(&settings_admin_cap);
```

`set_witness` is idempotent when the same type is already active. Replacing it
immediately rejects the old witness while preserving the Registry and its sequence.
Multiple purchase methods that coexist should live behind one sales package's
module-controlled witness.

The sales path consumes that witness when minting:

```move
let record = record::mint<miso_pressing::pressing::MintWitness, Currency>(
    registry,
    settings,
    pressing::MintWitness(),
    release_id,
    clock,
    ctx,
);
```

`mint` reads Settings through `&Settings` and mutates the Registry. Governance
should select only a non-copyable witness with a suitably restricted constructor.

## Stored provenance

The Record module stamps rather than trusts independently supplied values:

- `registry_id` comes from the actual Registry object used to claim the UID.
- `number` is allocated by the Registry and participates in
  `RecordKey(release_id, number)`.
- `created_at_ms` comes from Sui's `Clock`.
- `purchase_currency` comes from the `Currency` type argument.
- `purchased_by` comes from the transaction sender.

`purchased_by` is the original purchaser, not the current owner and not necessarily
the transfer recipient. The authorized witness type remains in
`RecordCreatedEvent` for audit and indexing but is not stored in the Record.

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
| `RecordRegistryCreatedEvent` | Canonical Registry ID |
| `RecordCreatedEvent` | Record, Registry, release, number, creation time, purchase currency, purchaser, witness type |
| `RecordDestroyedEvent` | Record and release |
| `SettingsCreatedEvent` | Settings and admin-cap IDs |
| `WitnessSetEvent` | Settings, previous witness, and new witness |
| `WitnessClearedEvent` | Settings and removed witness |

## Layout

```text
Move.toml
sources/
  record.move
  settings.move
tests/
  record_tests.move
```

## Build

```bash
sui move test
```

This architecture changes the Record layout, abilities, Settings layout, and mint API
and therefore requires a fresh publication. Sales, Seal-policy, SDK, and application
consumers must update to the new Registry and framework transfer path.

License: Apache-2.0
