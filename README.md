# miso-record

The Miso record — an owned copy of a release on Sui. The core fixes only the release
and an issuer-defined certificate at birth; extensions can attach contextual state
through the record's UID.

```move
public struct Record<Certificate: drop + store> has key {
    id: UID,
    release_id: ID,
    certificate: Certificate,
}
```

The concrete certificate type identifies the mint path, while its value carries that
path's immutable facts. For example, `miso_pressing::certificate::Certificate` stores
the pressing, number, payment, and timestamp. It is embedded—not a detachable dynamic
field.

## Design

- **Release by `ID` only.** The core stores the release's `ID`, not a typed `Release`,
  so it has **no dependency on the protocol**. Extensions that need the typed release
  bring that dependency themselves.

- **Trust is expressed by the exact record type.** `record::new` embeds a certificate
  value and returns its specialization:

  ```move
  public fun new<C: drop + store>(parent: &mut UID, certificate: C, release_id: ID, number: u64): Record<C>
  ```

  Anyone may define a certificate type, but consumers choose which exact `Record<C>`
  types they trust. A trusted certificate module restricts construction and omits
  `copy`, preventing outsiders from minting or duplicating that specialization.

- **Every record derives off its minting context.** `new` claims the record's UID off
  a `parent: &mut UID` (e.g. a `Pressing`'s UID) keyed by `RecordKey(number)`, so every
  copy is deterministically addressable from its parent and a claim slot can be minted
  at most once per parent. The record does not *store* the number — the core keeps
  numbers as pure addressing (`derive_address(parent, number)` precomputes the
  address); the readable meaning of a number belongs to the certificate.
  There is deliberately no fresh-UID mint: a gifting or airdrop package derives off an
  object of its own.

- **Otherwise, authority is possession.** Once a record exists, only the owner can
  produce a `&mut Record`, so `uid_mut` is fully open — no capability, no allowlist:

  ```move
  public fun uid<C: drop + store>(self: &Record<C>): &UID
  public fun uid_mut<C: drop + store>(self: &mut Record<C>): &mut UID
  ```

- **Transfer is explicit, sharing and freezing are unavailable.** `Record` omits
  `store`, so another package cannot use `public_transfer`, `public_share_object`,
  `public_freeze_object`, or wrap it. The core exposes the one intended by-value path:

  ```move
  public fun transfer<C: drop + store>(record: Record<C>, recipient: address)
  ```

  It performs the module-restricted `transfer::transfer`. The core exposes no share or
  freeze function.

## Events

Creation and destruction events are phantom-typed by certificate, so indexers can
filter the exact trusted record specialization.

| Event | Indexed facts |
|---|---|
| `RecordCreatedEvent<Certificate>` | record, minting parent, release, claim number |
| `RecordDestroyedEvent<Certificate>` | record, release |

## Gating on a record

Gated material — a release mix, stems, or a scan of the lyric sheet — is opened against
a proof, not a lookup. The
[`miso_record_seal_policy`](https://github.com/misofm/record-extensions/tree/main/miso_record_seal_policy)
package provides a [Seal](https://docs.sui.io/sui-stack/seal/using-seal) policy that
takes `&Record<C>` together with an immutable gate for the exact trusted certificate
type. This is safe specifically because `Record` is key-only and the core exposes no
share or freeze path: Seal accepts only direct PTB inputs, resolves their current
on-chain versions, and simulates with sender/owner checks. A private `entry` function
alone is not the ownership proof.

## Layout

```
move/
  sources/record.move     the slim Record
  tests/record_tests.move
```

The `Pressing` lives in the sibling `miso_pressing` package and defines its own
certificate. Other mint paths define other certificate types. Extensions to the
record itself live under `record-extensions`.

## Build

```bash
cd move && sui move test
```

## Status

| Package | State |
|---|---|
| `miso_record` | ✅ typed certificate, key-only transfer control, registry-free core |

This layout is incompatible with the previous published package and requires a fresh
publication: removing `store` changes the `Record` abilities. Existing package IDs do
not identify this key-only architecture.

License: Apache-2.0
