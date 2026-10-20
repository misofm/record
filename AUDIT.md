# Security Review — `record`

**Date:** 2026-10-20 · **Toolchain:** Sui 1.82.1

Review of edition-scoped Pressings, Distributor authorization, and composable
Records. Verdict: **safe under the documented capability and witness model — no
findings.**

## Security model

- `pressing::new` requires the Release's matching `ReleaseAdminCap` and claims
  `PressingKey(edition)` from that Release's UID. Editions start at 1 and are
  created in order (`EPreviousEditionMissing`).
- Every Pressing owns one edition's monotonically increasing `supply`, a required
  positive immutable `max_supply: u32`, and a `VecSet<TypeName>` of authorized
  Distributors.
- `PressingAdminCap` is derived from and bound to one Pressing ID. It authorizes
  Distributor changes and mutable Pressing UID access.
- `pressing::press<Distributor, Currency>` checks the Distributor type and the
  supply cap, allocates the next number, and calls the package-private Record
  constructor.
- Every Record ID is claimed from its Pressing at `RecordKey(number)`.
- Record has `key + store`, so ownership is deliberately composable.

## Checks performed

- **Record construction is closed.** `record::new` is `public(package)` and only
  `pressing::press` reaches it. Distributors cannot select lineage, currency type,
  purchase time, or Record number.
- **Pressing construction is Release-authorized.** `release::uid_mut` rejects a
  mismatched Release cap. `PressingKey(edition)` makes each `(release, edition)`
  claim-once. Pressings can be created before or after the Release is published.
- **Numbers are edition-local and not caller-selected.** Each Pressing allocates
  `1, 2, 3…` internally; equal numbers in different editions derive different IDs.
- **Failed purchases do not consume numbers.** Authorization and the cap are
  checked before mutation; any later abort rolls back atomically.
- **Supply caps are immutable.** `max_supply` must be positive and has no setter.
  Destroying a Record does not restore capacity. `u32::MAX` is accepted.
- **Distributor identity is exact and edition-scoped.** Authorization and pressing
  both use `type_name::with_defining_ids<Distributor>()`. Authorization on one
  Pressing grants nothing on another. Add and revoke are idempotent and emit an
  event only when the set changes.
- **Witness values are consumed.** A Distributor witness should have only `drop`
  and a module-restricted constructor.
- **Stored purchase data is internally bound.** Release, Pressing, and edition come
  from the Pressing; number from its counter; currency from the concrete type;
  purchase time from `Clock`. The authorized Distributor supplies the price after
  validating payment; 0 is a free Record. The buyer is the purchase transaction's
  sender and is not stored.
- **Distributor storage is small and inline.** `VecSet` membership is O(n), suited
  to a handful of issuance paths, not an unbounded registry.
- **Pressings are permanent.** There is no destructor that could strand the derived
  Record namespace.
- **Ownership is unrestricted.** `store` permits framework transfer, wrapping,
  sharing, and freezing. An immutable `&Record` is not ownership proof.
- **Extension authority follows mutable access.** `Record::uid_mut` is open, so
  sharing a Record makes extension mutation public. `Pressing::uid_mut` is
  cap-gated.

## Deliberate tradeoffs

- Every press mutates its Pressing; presses within one edition serialize, unrelated
  editions do not contend.
- Distributor authorization is per Pressing; there is no package-wide kill switch.
- A compromised Pressing cap can authorize a malicious Distributor or modify
  cap-gated extensions. It cannot change `max_supply` or select a Record number.

## Operational requirements

Each `PressingAdminCap` needs suitable custody. Loss prevents Distributor rotation;
compromise permits new issuance paths. Authorize a replacement Distributor before
revoking the old one. Never authorize a publicly constructible witness.

Clients derive every Pressing and Record ID from `(release_id, edition, number)`.

## Verification

40 Move unit tests, 100% line coverage. They cover Release-derived Pressing
identity (unpublished and published Releases), duplicate and out-of-order editions,
mismatched Release and Pressing caps, zero and `u32::MAX` supply caps, edition-local
sequences, Distributor authorization, revocation and replacement, free and
`u64::MAX` prices, per-currency provenance, events, extensions, shared Pressings,
destruction, and framework public transfer.
