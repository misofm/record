# Edition-scoped Pressing and Record

> **2026-09-01 — current direction.** `miso_record` owns the Record lifecycle. Each
> Release derives one Pressing per edition; each Pressing owns its supply, optional
> maximum, Record namespace, and authorized Distributor witness types.

## Core

- [x] Keep one concrete `Record` with `key + store`.
- [x] Add `Pressing` to `miso_record` as the lifecycle and issuance boundary.
- [x] Derive each Pressing from its Release at `PressingKey(edition)`.
- [x] Store `release_id`, `pressing_id`, edition-local `number`, `edition`, and
      Clock-stamped `created_at_ms` on each Record.
- [x] Derive Record UIDs from `(pressing_id, RecordKey(number))`.
- [x] Track edition-local supply directly on the Pressing.
- [x] Version Pressings and fail closed on unsupported representations.
- [x] Support immutable `Option<u64>` maximum supply.
- [x] Authorize multiple Distributor witness types per Pressing with `VecSet`.
- [x] Add idempotent Distributor authorization and revocation.
- [x] Keep Distributor type in `RecordCreated`, not in Record storage.
- [x] Remove the singleton Registry, Table, Settings, and package initializer.
- [x] Keep Record extension UID access, explicit destruction, and framework
      `public_*` ownership operations.
- [x] Cover derived identities, edition-local numbering, caps, Distributor rotation,
      authorization failures, provenance, extensions, destruction, and transfer.

## Design consequences

- Mints within one edition serialize on that Pressing's counter. Different editions
  can mint independently.
- A Distributor replacement preserves the Pressing ID and its sequence. Authorize the
  replacement before revoking the old type.
- Distributor packages own sales, redemption, migration, airdrop, payment, schedule,
  and delivery mechanics.
- Maximum supply is a permanent edition invariant. A different cap requires a new
  edition and Pressing.
- `key + store` permits transfer, wrapping, sharing, and freezing. Downstream access
  policies may not treat `&Record` alone as proof of direct address ownership.

## Integration follow-ups

- [ ] Replace the old `miso_pressing` package with one or more Distributor packages.
- [ ] Update Distributor calls to use `pressing::mint(witness, clock)`.
- [ ] Update SDK/application transaction construction with `pressing_id` and edition.
- [ ] Add Distributor-specific purchase/payment provenance where required.
- [ ] Redesign the Record Seal policy's ownership proof for `key + store`.
- [ ] Add a migration Distributor for Records from earlier package publications.
- [ ] Fresh-publish `miso_record` and configure Pressing and Distributor IDs.
