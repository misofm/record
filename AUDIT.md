# Security Review — `miso_record`

**Revision:** working tree · **Date:** 2026-09-01 · **Toolchain:** Sui 1.78.1

Review of edition-scoped Pressings, Distributor authorization, and composable
Records. Verdict: **safe under the documented capability and witness model — no
findings.**

## Security model

- `pressing::new` requires a Release's matching `ReleaseAdminCap` and claims
  `PressingKey(edition)` from that Release's UID.
- Every Pressing owns one edition's monotonically increasing `supply`, optional
  immutable `max_supply`, and `VecSet<TypeName>` of authorized Distributors.
- `PressingAdminCap` authorizes Distributor changes and mutable Pressing extension
  access. It is derived from and bound to one Pressing ID.
- `pressing::mint<Distributor, Currency>` checks the Distributor type, positive
  purchase price, and optional maximum; allocates the next number; and calls the
  package-private Record constructor.
- Every Record ID is claimed from its Pressing at `RecordKey(number)`.
- Record has `key + store`, so ownership is deliberately composable rather than
  module-restricted.

## Checks performed

- **Record construction is closed.** The production constructor is
  `public(package)`, and only `pressing::mint` reaches it. External Distributors
  cannot select lineage, currency type, buyer, timestamp, or Record number.
- **Pressing construction is Release-authorized.** `release::uid_mut` rejects a
  mismatched Release cap. `PressingKey(edition)` makes each `(release, edition)`
  canonical and claim-once.
- **Numbers are edition-local and cannot be caller-selected.** Each Pressing starts
  at zero and allocates `1, 2, 3…` internally. Different editions use independent
  Pressing objects and independent sequences.
- **The derivation chain is fully scoped.** A Pressing derives from `(release,
  edition)`, and a Record derives from `(pressing, number)`. Equal Record numbers in
  different editions cannot collide.
- **Failed purchases do not consume numbers.** Authorization, positive purchase
  price, and maximum supply are checked before mutation. Any later abort rolls the
  increment and derived-object claim back atomically.
- **Supply caps are core and immutable.** `none()` is uncapped; `some(n)` requires
  `n > 0`. There is no setter that can weaken or revise the edition's stated cap.
- **Distributor identity is exact and edition-scoped.** Authorization and mint both
  use `type_name::with_defining_ids<Distributor>()`. A separately published
  identically named type is not authorized accidentally, and authorization on one
  Pressing grants nothing on another.
- **Distributor rotation preserves identity.** Multiple types may coexist. Adding a
  replacement before revoking the old type retains the same Pressing, supply, and
  Record namespace. Add and revoke operations are idempotent.
- **Witness values are consumed.** A recommended witness has only `drop` and a
  restricted constructor, so it cannot be copied or stored for later minting.
- **Stored purchase data is internally bound.** Release, Pressing, and edition come
  from the actual Pressing; number comes from its counter; Record ID uses that number;
  currency comes from the concrete type; buyer comes from `TxContext`; and purchase
  time comes from `Clock`. The authorized Distributor supplies the positive price
  after validating payment. Distributor type remains event-only audit provenance.
- **Distributor storage is intentionally small and inline.** `VecSet` gives simple
  duplicate-free membership. Its O(n) behavior is appropriate for a handful of
  issuance paths; it is not intended as an unbounded registry.
- **Pressings are permanent.** There is no destructor that could strand the derived
  Record namespace. Mutable UID access requires the matching Pressing cap.
- **Ownership is explicitly unrestricted.** Record exposes no redundant transfer
  wrapper. Its `store` ability permits framework transfer, wrapping, sharing, and
  freezing.
- **Immutable borrowing is not ownership proof.** Shared and frozen Records may be
  passed by immutable reference by non-owners. Downstream access policies must prove
  an acceptable ownership mode separately.
- **Extension authority follows mutable access.** `uid_mut` is intentionally open.
  Sharing a Record therefore makes extension mutation public as well.

## Deliberate tradeoffs

- Every mint mutates its Pressing because `supply` is the sequence. Mints within one
  edition serialize; unrelated editions do not contend on a global root.
- Distributor authorization is deliberately per Pressing. There is no package-wide
  kill switch; revocation must be applied to each affected edition.
- A compromised Pressing cap can authorize a malicious Distributor or modify
  cap-gated extensions. It cannot rewrite the immutable maximum or directly select a
  Record number through any public API.
- Currency, positive price, buyer, and purchase time are Record invariants. The
  authorized Distributor must validate that the supplied price equals the payment it
  accepted. Pricing rule, schedule, and final recipient remain Distributor concerns.

## Operational requirements

Each `PressingAdminCap` should use suitable capability custody. Loss prevents
Distributor rotation and cap-authorized extension changes for that edition;
compromise permits new issuance paths. A replacement Distributor should be authorized
and tested before the old witness is revoked.

Distributor witnesses must have restricted constructors and must never be returned or
stored. Authorizing a publicly constructible witness would make minting permissionless
until that type is revoked.

Clients can derive every Pressing and Record ID from `(release_id, edition, number)`.
Deployment configuration therefore tracks active Pressing IDs and Distributor package
IDs, not singleton Registry or Settings IDs.

## Verification

Fourteen Move unit tests cover Release-derived Pressing identity, duplicate-edition
rejection, edition validation, capped and uncapped supply, edition-local sequences,
Distributor authorization, revocation and replacement, mismatched capabilities,
positive purchase prices, complete purchase provenance, Record and Pressing
extension access, shared Pressings, destruction, and framework public transfer.
