# miso-record

The Miso record — an owned, ownable copy of a release, on Sui. A deliberately slim
core that gains all its functionality from extensions — the same slim-core +
raw-`&mut UID` model as `miso-player` and the miso-protocol.

```move
public struct Record has key, store {
    id: UID,
    release_id: ID,
    edition: u32,               // which edition run (0 = first)
    number: u64,                // serial within the edition
    purchase_currency: TypeName,
    purchase_price: u64,
}
```

That's the whole object. A `Record` is **owned** and **transferable**. Sale logic,
statistics, vouchers, SEAL access — none of it lives in the struct. Each is an
extension package that attaches its own state to the record's `UID` as a dynamic field.

## Design

- **Release by `ID` only.** The core stores the release's `ID`, not a typed `Release`,
  so it has **no dependency on the protocol**. Extensions that need the typed release
  bring that dependency themselves.

- **Minting is authorized by type; sale mechanics live in their own packages.** A
  record only comes into being through `record::mint` / `record::mint_derived`, each
  of which requires a *witness* whose **type** is on the `Settings` allowlist:

  ```move
  public fun mint<W: drop, Currency>(_w: W, settings: &Settings, release_id: ID, edition: u32, number: u64, purchase_price: u64, ctx): Record
  public fun mint_derived<W: drop, Currency>(_w: W, settings: &Settings, parent: &mut UID, release_id: ID, edition: u32, number: u64, purchase_price: u64, ctx): Record
  ```

  `Settings` (shared) holds a `VecSet<TypeName>` of authorized minter witnesses,
  managed by a `SettingsAdminCap`. A sale package defines its own witness, mints it
  only on its paid path, and hands it to `mint`; the check is a runtime `TypeName`
  lookup, never a compile-time dependency on the sale package. **A brand-new sale
  package plugs in with zero redeploy of this package** — an admin just authorizes its
  witness type. This is why the sale lives in its own package
  ([`miso-drop`](https://github.com/misonetwork/miso-drop), witness
  `miso_drop::drop::MintWitness`): same `Record`, different shops, different sale
  mechanics.

- **Records derive off the sale.** `mint_derived` claims the record's UID off a
  `parent: &mut UID` (e.g. a `Drop`'s UID) keyed by `RecordKey(number)`, so every copy
  is deterministically addressable from its sale and a given number can be minted
  at most once. `record::is_derived_from(&record, drop_id)` verifies that linkage
  on-chain from the record alone — no stored parent id needed.

- **Otherwise, authority is possession.** Once a record exists, only the owner can
  produce a `&mut Record`, so `uid_mut` is fully open — no capability, no allowlist:

  ```move
  public fun uid(self: &Record): &UID
  public fun uid_mut(self: &mut Record): &mut UID
  ```

## Layout

```
move/
  sources/record.move     the slim Record
  sources/settings.move   Settings — the witness-type mint allowlist
  tests/record_tests.move
```

The V1 sale — the `Drop` — lives in its own repo:
[`miso-drop`](https://github.com/misonetwork/miso-drop). A second sale mechanic
(auction, dutch, giveaway…) would be another sibling package, each authorized by its
own witness type in `Settings`.

## Build

```bash
cd move && sui move test
```

## Status

| Package | State |
|---|---|
| `miso_record` | ✅ slim struct + `Settings` witness-gated mint, 4 tests |

Further extensions (statistics, vouchers, SEAL ACL) attach to a record's `UID` and are
the next pieces.

License: Apache-2.0
