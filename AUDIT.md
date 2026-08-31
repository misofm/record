# Security Review — `miso_record`

**Revision:** working tree · **Date:** 2026-09-01 · **Toolchain:** Sui 1.78.1

Review of the concrete composable Record, singleton Registry, and single-witness
creation policy. Verdict: **safe under the documented ownership and serialization
model — no findings.**

## Security model

- `record::init` creates and shares the only production `RecordRegistry`.
- The Registry stores one monotonically increasing counter per release in
  `Table<ID, u64>`.
- `settings::init` creates and shares the only production `Settings`, then
  transfers its `SettingsAdminCap` to the publisher.
- `settings::set_witness<W>` atomically makes `W` the only authorized witness;
  `clear_witness` disables Record creation. Both require the admin cap.
- `record::mint<W, Currency>` checks the active witness before mutating the Registry.
- Every Record ID is claimed from the Registry at
  `RecordKey(release_id, number)`, where `number` was allocated by the Registry.
- Record has `key + store`, so ownership is deliberately composable rather than
  module-restricted.

## Checks performed

- **Record construction is closed.** Record fields are module-private and the only
  production constructor is witness-gated `mint`. There is no raw constructor or
  generic Record specialization.
- **Registry construction is closed.** Its production constructor is private and
  reached only by module initialization. External packages cannot create an alternate
  Registry accepted as canonical deployment state.
- **Numbers cannot be caller-selected.** `mint` reads and advances the counter keyed
  by `release_id`. A new release starts at 1; existing releases continue their prior
  sequence after sales-witness replacement.
- **The derivation key is fully scoped.** `RecordKey(release_id, number)` prevents
  equal numbers for different releases from colliding while binding each Record ID to
  both immutable values.
- **Failed mints do not consume numbers.** Authorization is checked before mutation,
  and any later abort rolls the entire transaction—including the Table update and
  derived-object claim—back atomically.
- **Settings contains at most one authority.** Its field is `Option<TypeName>`, not
  a collection. Setting a replacement is atomic and immediately rejects the previous
  type; clearing is idempotent and leaves no authorized witness.
- **Witness identity is exact.** Settings and mint both use
  `type_name::with_defining_ids<W>()`. A separately published identically named type
  is not authorized accidentally.
- **Witness values are consumed.** A recommended witness has only `drop` and a
  restricted constructor, so it cannot be copied or stored for later minting.
- **Stored provenance is internally bound.** `registry_id` comes from the actual
  Registry input; `number` is the Registry allocation used in `RecordKey`;
  `created_at_ms` comes from `Clock`; `purchase_currency` comes from the generic
  type; and `purchased_by` comes from the transaction sender. The witness remains
  event-only audit provenance.
- **The per-release map scales out of line.** Supplies live as Table entries rather
  than inline vector state, avoiding linear lookup and Registry object-size growth.
  The Registry is permanent; no destructor can orphan its Table entries.
- **Ownership is explicitly unrestricted.** Record exposes no redundant transfer
  wrapper. Its `store` ability permits framework transfer, wrapping, sharing, and
  freezing.
- **Immutable borrowing is not ownership proof.** Shared and frozen Records may be
  passed by immutable reference by non-owners. Downstream access policies must prove
  an acceptable ownership mode separately.
- **Extension authority follows mutable access.** `uid_mut` is intentionally open.
  Sharing a Record therefore makes extension mutation public as well.

## Deliberate tradeoffs

- Every mint takes `&mut RecordRegistry`. Even though supplies are Table entries,
  unrelated releases contend on the same shared Registry input. This is intentional:
  the singleton root, not a replaceable sales package, is the canonical namespace.
- Replacing the one active witness disables every path behind the old package
  immediately. Concurrent sale styles must share one trusted witness package.
- `purchased_by` records the transaction sender. It is not the transfer recipient,
  current owner, payer account in an external abstraction, or proof that payment was
  economically sufficient; the authorized sales witness is responsible for payment
  validation.

## Operational requirements

The `SettingsAdminCap` should be held by Miso governance or suitable capability
custody. Loss prevents sales-package rotation; compromise permits replacement with a
publicly constructible witness. Rotation should be tested in one transaction before
retiring the old sales deployment.

Deployment configuration must pin the canonical Registry and Settings object IDs from
the Record package publication. Passing a different object of either static type is
not possible in production today because their constructors are closed, but explicit
pinning prevents operational ambiguity and supports client-side validation.

## Verification

Ten Move unit tests cover provenance stamping, Registry initialization, independent
per-release sequences, sequence continuity across witness replacement, unauthorized,
cleared, and replaced witness rejection, idempotent Settings events, dynamic-field
extension access, destruction, and framework public transfer.
