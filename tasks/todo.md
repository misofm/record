# Registry-sequenced Record

> **2026-09-01 — current direction.** Record is Miso's concrete distribution format.
> One singleton Registry owns its stable UID namespace and per-release sequences; one
> rotatable witness type selects the complete active sales implementation.

## Core

- [x] Replace `Record<Certificate>` with one concrete Record.
- [x] Store `release_id`, `registry_id`, Registry-allocated `number`,
      Clock-stamped `created_at_ms`, type-stamped `purchase_currency`, and
      transaction-stamped `purchased_by`.
- [x] Add singleton shared `RecordRegistry { id, supplies: Table<ID, u64> }`.
- [x] Allocate per-release numbers inside `record::mint` and derive every Record
      UID from `(Registry, RecordKey(release_id, number))`.
- [x] Replace the witness `VecSet` with one `Option<TypeName>`.
- [x] Add atomic, idempotent `set_witness<W>` and idempotent `clear_witness`.
- [x] Keep the consumed witness in `RecordCreatedEvent`, not in Record storage.
- [x] Give Record `key + store` and remove its explicit transfer wrapper; callers
      use framework `public_*` operations.
- [x] Keep extension UID access and explicit destruction.
- [x] Cover Registry continuity across witness replacement, per-release numbering,
      provenance stamping, authorization replacement/clearing, initialization,
      extensions, destruction, and framework transfer.

## Design consequences

- Every Record mint mutates the singleton Registry. Global sequencing is intentional,
  even though it prevents unrelated Record mints from executing in parallel.
- Replacing the active witness disables the old sales package immediately but does
  not change Record addresses or restart numbering.
- Multiple simultaneous purchase mechanics must be implemented behind the one active
  sales witness.
- `key + store` permits transfer, wrapping, sharing, and freezing. Downstream access
  policies may not treat `&Record` alone as proof of direct address ownership.

## Integration follow-ups

- [ ] Update `miso_pressing` to pass `&mut RecordRegistry`, `Currency`, Clock,
      and TxContext to `record::mint`.
- [ ] Replace `settings::authorize` calls with `settings::set_witness`.
- [ ] Update SDK/application transaction construction with the Registry shared input.
- [ ] Replace `record::transfer` calls with framework transfer commands.
- [ ] Redesign the Record Seal policy's ownership proof for `key + store`.
- [ ] Fresh-publish `miso_record` and configure Registry, Settings, and admin-cap IDs.
