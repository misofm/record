# miso-record

The Miso record — an owned, ownable copy of a release, on Sui. A deliberately slim
core that gains all its functionality from extensions — the same slim-core +
raw-`&mut UID` model as `miso-player` and the miso-protocol.

```move
public struct Record has key, store {
    id: UID,
    release_id: ID,
    edition: u32,               // which pressing run (0 = first pressing)
    number: u64,                // serial within the pressing
    purchase_currency: TypeName,
    purchase_price: u64,
}
```

That's the whole object. A `Record` is **owned** and **transferable**. Pressing logic,
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
  witness type. This is why `miso_pressing` is a *separate package*: same `Record`,
  different shops, different sale mechanics.

- **Records derive off the pressing.** `mint_derived` claims the record's UID off a
  `parent: &mut UID` (the `Pressing`'s UID) keyed by `RecordKey(number)`, so every copy
  is deterministically addressable from its pressing and a given number can be pressed
  at most once. `record::is_derived_from(&record, pressing_id)` verifies that linkage
  on-chain from the record alone — no stored parent id needed.

- **Otherwise, authority is possession.** Once a record exists, only the owner can
  produce a `&mut Record`, so `uid_mut` is fully open — no capability, no allowlist:

  ```move
  public fun uid(self: &Record): &UID
  public fun uid_mut(self: &mut Record): &mut UID
  ```

## `miso_pressing` — the V1 sale

A `Pressing<Currency>` is a shared, **immutable** primary sale for one *edition* of a
release. It never gates *who* can buy — supply is uncapped and access is open; how rare
a record becomes is about how its owner engages with it over time, not manufactured
scarcity at the point of sale.

- **Editions.** Pressing UIDs are derived off a shared `PressingRegistry` keyed by
  `(release_id, edition)`, giving deterministic addressing and **gap-free** per-release
  runs: `0, 1, 2, …` (creating edition `n` requires `n-1` to exist; duplicates abort).
- **Price.** `Fixed` (pay exactly) or `Floor` (pay ≥, overpayment kept as a tip). The
  whole payment forwards to the release's address; the record stores what was paid.
- **Window (the only mechanic).** Sells within `[start, end?]`; `end` is optional
  (`none` = evergreen, always buyable). Liveness is a pure function of the clock — no
  manual pause. End a limited run with a close set up front; offer more with a new
  edition.

## Layout

```
move/
  core/       miso_record   — the slim Record + Settings mint-authority (this package)
  pressing/   miso_pressing — the V1 primary sale; presses records via its MintWitness
```

`miso_pressing` depends on `miso_record` (and on `miso` for the release admin cap). A
second sale mechanic (auction, dutch, giveaway…) would be another package alongside
`pressing/`, each authorized by its own witness type in `Settings`.

## Build

```bash
cd move/core     && sui move test   # miso_record
cd move/pressing && sui move test   # miso_pressing
```

## Status

| Package | State |
|---|---|
| `miso_record` (core) | ✅ slim struct + `Settings` witness-gated mint, 4 tests |
| `miso_pressing` | ✅ immutable `Pressing<Currency>`: editions, fixed/floor price, time window, 11 tests |

Further extensions (statistics, vouchers, SEAL ACL) attach to a record's `UID` and are
the next pieces.

License: Apache-2.0
