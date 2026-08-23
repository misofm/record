# Security Audit — `miso_record`

**Revision:** not a git repository (working tree as of audit date) · **Date:** 2026-08-23 ·
**Toolchain:** sui 1.77.2

Audit of `miso_record`, the owned-copy-of-a-release primitive: a
`Record<Certificate>` (key + store) with a permanently embedded,
issuer-defined certificate and derived-object minting. Verdict: **safe — no
findings.**

## What it does

- `new<Certificate: drop + store>` (`record.move:61`) — mints a `Record`
  whose UID is **derived** from the issuer's parent UID via
  `derived_object::claim(parent, RecordKey(number))` (`:69`), guaranteeing a
  unique, predictable record id per `(parent, number)`.
- `destroy` (`:84`) — consumes the record; the embedded certificate dies with
  it.
- `uid`/`uid_mut` (`:93`, `:97`) — possession-is-authority extension access.
- `derive_address` (`:112`) — pure view for pre-computing record addresses.

Threat model: forged provenance (a record claiming a trusted issuance path);
record id collisions or squatting; unauthorized extension mutation.

## Checks performed (all hold)

- **Certificate authenticity is type-level.** The `Certificate` is a private
  field set once at `new` and never mutable or detachable (`:30`, no setter
  exists). Minting `Record<TrustedCert>` requires constructing
  `TrustedCert`, which a trusted issuer's package keeps module-private (the
  module doc states this contract explicitly, `:11-13`). An arbitrary package
  CAN mint `Record<TheirCertificate>` — by design; consumers must check the
  concrete certificate type, and both events carry `phantom Certificate` in
  the event TYPE (`:42`, `:51`) so untrusted specializations cannot pollute a
  trusted event stream.
- **Derived-id uniqueness.** `derived_object::claim` aborts if the
  `(parent, RecordKey(number))` address is already claimed — no collisions,
  no squatting on someone else's parent (claiming requires `&mut parent`
  UID). `RecordKey(u64)` is module-private-constructible (`:36`), so no
  other package can derive into this key namespace.
- **Possession-is-authority is sound here.** `uid_mut` (`:97`) is ungated —
  but `Record` is `key + store`, so only a transaction that can produce
  `&mut Record` (its owner, or code it was passed to) can reach it. Dynamic
  field extensions on the record UID are the holder's own business;
  destroying a record with extensions attached is the holder's loss, not a
  protocol risk (`destroy` doc, `:82-83`).
- **No funds surface.** No balances, no transfers, no arithmetic beyond the
  derived key.

## Findings

None.

## Edge cases (verified)

- **Double mint with same `(parent, number)`** — aborts in
  `derived_object::claim`.
- **`number` semantics** — issuer-defined by design (`:34-35`); collision
  resistance is inherited from the derived-object layer regardless.
- **Destroy with dynamic fields attached** — allowed; df values with `store`
  are recoverable only if removed first (documented at `:82`). The embedded
  certificate is destroyed unconditionally — intended.
- **Cross-specialization confusion** — events and views are
  `Certificate`-parameterized; `record::certificate` returns `&Certificate`
  typed at the call site.

## Verification

5 unit tests (`tests/record_tests.move`). The derived-object claim semantics
were cross-checked against usage in the pressing package (the only in-repo
minting issuer), which satisfies the private-certificate contract.
