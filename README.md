# miso-record

The Miso record — an owned, ownable copy of a release, on Sui. A deliberately slim
core that gains all its functionality from extensions — the same slim-core +
raw-`&mut UID` model as `miso-player` and the miso-protocol.

```move
public struct Record has key, store {
    id: UID,
    release_id: ID,
    created_at_ms: u64,   // stamped off the Clock at mint — never supplied by the minter
}
```

That's the whole object — only what is fixed at birth, true forever, and meaningful
without a namespace. A `Record` is **owned** and **transferable**. Serial numbers,
sale terms, statistics, playtime, vouchers, SEAL access — none of it lives in the
struct. Each is an extension package that attaches its own state to the record's
`UID` as a dynamic field: the serial certificate and purchase receipt are
`miso_pressing`'s, because a serial is only meaningful inside the sequence that issued
it — two sale packages for the same release each count from 1, so "copy 42" is
always "copy 42 *of this pressing*", never a bare 42.

## Design

- **Release by `ID` only.** The core stores the release's `ID`, not a typed `Release`,
  so it has **no dependency on the protocol**. Extensions that need the typed release
  bring that dependency themselves.

- **Minting is authorized by type; sale mechanics live in their own packages.** A
  record only comes into being through `record::mint`, which requires a *witness*
  whose **type** is on the `Settings` allowlist:

  ```move
  public fun mint<W: drop>(_w: W, settings: &Settings, parent: &mut UID, release_id: ID, number: u64, clock: &Clock, ctx): Record
  ```

  `Settings` (shared) holds a `VecSet<TypeName>` of authorized minter witnesses,
  managed by a `SettingsAdminCap`. A sale package defines its own witness, mints it
  only on its paid path, and hands it to `mint`; the check is a runtime `TypeName`
  lookup, never a compile-time dependency on the sale package. **A brand-new sale
  package plugs in with zero redeploy of this package** — an admin just authorizes its
  witness type. This is why the sale lives in its own package
  ([`miso-pressing`](https://github.com/misonetwork/miso-pressing), package `miso_pressing`,
  witness `miso_pressing::pressing::MintWitness`): same `Record`, different shops,
  different sale mechanics.

- **Every record derives off its minting context.** `mint` claims the record's UID off
  a `parent: &mut UID` (e.g. a `Pressing`'s UID) keyed by `RecordKey(number)`, so every
  copy is deterministically addressable from its parent and a claim slot can be minted
  at most once per parent. The record does not *store* the number — the core keeps
  serials as pure addressing (`derive_id(parent, number)` recomputes and thereby
  verifies the linkage); the readable serial is the issuing package's dynamic field.
  There is deliberately no fresh-UID mint: a gifting or airdrop package derives off an
  object of its own.

- **Otherwise, authority is possession.** Once a record exists, only the owner can
  produce a `&mut Record`, so `uid_mut` is fully open — no capability, no allowlist:

  ```move
  public fun uid(self: &Record): &UID
  public fun uid_mut(self: &mut Record): &mut UID
  ```

## Events

The core emits a complete indexing surface:

| Event | Indexed facts |
|---|---|
| `SettingsCreatedEvent` | settings object, admin capability, initial admin |
| `MinterAuthorizedEvent` | settings object, admin capability, witness type, actor |
| `MinterRevokedEvent` | settings object, admin capability, witness type, actor |
| `RecordCreatedEvent` | record, minting parent, release, claim number, timestamp, witness type, creator |
| `RecordDestroyedEvent` | record, release, actor |

The package can be immutable while the allowlist remains operational: immutability
removes `UpgradeCap` custody, while `SettingsAdminCap` is retained solely to authorize
or revoke minter witness types.

## Gating on a record

Gated material — a recording's stems, a mixer session, a scan of the lyric sheet — is
opened against a proof, not a lookup: a verifier simulates a transaction with the
claimed wallet as sender, and success *is* the authorization. That lives in
[`miso_record_acl`](https://github.com/misonetwork/miso-record-extensions/tree/main/miso_record_acl),
a [Seal](https://seal-docs.wal.app) decryption policy whose `seal_approve_*` entries take
the record **by value** — the whole security argument, since a `Record` has `store` and
`&Record` would let one shared copy open a release to everyone.

## Layout

```
move/
  sources/record.move     the slim Record
  sources/settings.move   Settings — the witness-type mint allowlist
  tests/record_tests.move
```

The V1 sale — the `Pressing` — lives in its own repo:
[`miso-pressing`](https://github.com/misonetwork/miso-pressing). A second sale mechanic
(auction, dutch, giveaway…) would be another sibling package, each authorized by its
own witness type in `Settings`. Extensions to the record itself live in
[`miso-record-extensions`](https://github.com/misonetwork/miso-record-extensions).

## Build

```bash
cd move && sui move test
```

## Status

| Package | State |
|---|---|
| `miso_record` | ✅ slim struct + `Settings` witness-gated mint, 6 tests |

### Testnet deployment

- Immutable package: `0x2f0e3cf7257f7ba6ee1109c741f0ccc39f44c2da610052d165e7b514c1149fd2`
- Shared `Settings`: `0xbc8468ea6fae4a1a0ba8f0dd2554fa75d2d3e1bff7537f866ad7b4b2f8d96e86`
- `SettingsAdminCap`: `0xfe6996468cd9a91c833d753df218cd311b3a8fa58c9085aac5104dcdca964c5a`
- Publish transaction: `9NkkYZk6FSpVACAvP6iB7g7nqv4d27p6T3coyKFSAwg`

Further extensions (statistics, vouchers) attach to a record's `UID` and are the next
pieces. They land in
[`miso-record-extensions`](https://github.com/misonetwork/miso-record-extensions),
alongside `miso_record_acl`.

License: Apache-2.0
