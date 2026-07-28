# Decouple drop from miso_record (witness-authorized mint)

Design B: `miso_record` is the base package and owns a `Settings` allowlist of
authorized minter *witness types*. Drop packages depend on `miso_record`, mint by
presenting their own witness, and `miso_record` checks the type is authorized.
A new drop package needs zero record redeploy — an admin authorizes its witness type.

## Plan

- [ ] `move/core/sources/settings.move` (NEW): `Settings` (shared, `VecSet<TypeName>`
      of authorized minters) + `SettingsAdminCap`, `init`, `authorize<W>`, `revoke<W>`,
      `is_authorized<W>`, events, test-only constructor.
- [ ] `move/core/sources/record.move`: replace open `new`/pkg-private `new_derived`
      with witness-gated `mint<W: drop>` and `mint_derived<W: drop>`; keep struct,
      destroy, uid/uid_mut, views. Add `minter: TypeName` to the created event.
- [ ] Delete `move/core/sources/drop.move` (moves to its own package).
- [ ] `move/drop/` (NEW package `miso_drop`): Move.toml (deps miso + miso_record),
      `sources/drop.move` — same `Drop<phantom Currency>`/pricing/lifecycle, but
      `buy` takes `&Settings` and mints via `record::mint_derived(MintWitness {}, …)`.
- [ ] Update `move/core/tests/record_tests.move` for the gated mint (authorized +
      unauthorized-aborts).
- [ ] `move/drop/tests/drop_tests.move` (NEW): full buy flow via `release::new_for_testing`.
- [ ] `sui move test` both packages; update README.

## Review (done)

- `move/core/sources/settings.move` — `Settings` (shared `VecSet<TypeName>`) +
  `SettingsAdminCap`, `init`, `authorize<W>`/`revoke<W>` (idempotent + events),
  `is_authorized<W>`, `minters`, test helpers.
- `move/core/sources/record.move` — open `new`/pkg-`new_derived` replaced by
  witness-gated `mint<W: drop>` / `mint_derived<W: drop>`; `number`/`RecordKey`
  widened to `u64`; event carries `minter: TypeName`.
- `move/core/sources/drop.move` — deleted (moved).
- `move/drop/` — new `miso_drop` package; `buy` takes `&Settings`, mints via
  `record::mint_derived(MintWitness {}, …, &mut self.id, …)`. u32 cast + overflow
  guard removed (u64 counter maps straight through).
- Tests: 4 core + 4 drop, all green. Cross-package unauthorized-witness abort proves
  the runtime `Settings` gate holds from an external package.
- Security: `MintWitness` (and any witness) is constructible only by its defining
  module, so only `miso_drop` can mint under its type; `Settings` is passed by
  *immutable* ref so concurrent buys don't serialize on it.

### Follow-ups / notes
- Breaking change vs. the deployed `miso_record` (drop::buy on testnet): fresh
  publish of both packages, then admin runs `settings::authorize<miso_drop::drop::MintWitness>`.
- `mint` (non-derived, fresh UID) is retained for future authorized minters
  (airdrops/gifts) that don't derive off a drop.

## Deviations from literal ask (consequences of Design B)
- `Drop` is `Drop<phantom Currency>` (record-specific), not generic over `<Item>`.
  "Same record, different mechanics" = different drop *packages*, each authorized by
  its witness type. (A generic `buy<Item>` can't call the Record-specific mint.)
- No hot-potato round-trip: `buy` mints atomically via a `drop` witness gated by
  `Settings`; the witness IS the "authorized type".
