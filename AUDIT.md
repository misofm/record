# Security Audit — `record`

Audited at `48ea9e774f0ff86487169c1f15aa0f5eff9e0cc2` (2026-10-21). Covers `record::pressing` and `record::record`, with `miso_music::release` (rev `1538d77`) and `sui::derived_object` read as dependencies.

## What it does

A `Pressing` is one numbered edition of a Release, derived from the Release UID at `PressingKey(edition)`; it holds the edition's supply counter, immutable `max_supply`, and the set of authorized Distributor witness types. `pressing::press` allocates the next number and mints a `Record` derived from the Pressing UID at `RecordKey(number)`. See [README](./README.md).

## Trust model

- **Release admin** (`&mut Release` + matching `ReleaseAdminCap`): creates Pressings for that Release, one per edition, in order (`pressing.move:70-109`). The Release cap is checked by `release::uid_mut` (`release.move:189`), not by this package.
- **Pressing admin** (`PressingAdminCap`, `key + store`, derived once from the Pressing at `PressingAdminCapKey()`, `pressing.move:87-90`): authorizes and revokes Distributor types and gets `&mut UID` of the Pressing (`pressing.move:188-209`). Cannot change `edition`, `max_supply`, `supply`, or choose Record numbers.
- **Distributor package**: any module that can construct an authorized witness type calls `press<Distributor, Currency>` on the shared Pressing and receives the Record (`pressing.move:115-142`). It alone decides `purchase_price` and the `Currency` type parameter; `record` does not see any payment.
- **Record holder**: `Record` is `key + store`; any holder can transfer, wrap, share, freeze, `destroy`, and use `uid_mut` (`record.move:34-39,79-81`).
- **Nobody** can construct a `Record` outside `pressing::press` (`record::new` is `public(package)`, `record.move:85`), construct `RecordKey`/`PressingKey`/`PressingAdminCapKey` from another module, mint a second admin cap for a Pressing, re-use a Record number, delete a Pressing, or raise `max_supply`.

## Findings

**R-01 · Info · Accepted — Distributors fully control `purchase_price` and the `Currency` type parameter.** `press` stores whatever the Distributor passes (`pressing.move:115-132`); `Currency` is an unconstrained type parameter, so a Distributor can stamp a non-coin type and any price (0 or `u64::MAX`) as provenance. Each Pressing authorizes its own Distributors, so this is a per-edition trust decision, not an exploit; documented in the README.

**R-02 · Info · Accepted — Destroying a Record orphans its dynamic fields and never frees its number.** `record::destroy` deletes the UID without checking for children (`record.move:34-39`); fields added via `uid_mut` become unreachable. The `Claimed(id)` marker stays on the Pressing forever (`derived_object::claim` never removes it), so storage per pressed number is permanent and `supply` is lifetime issuance, as the README states.

**R-03 · Info · Accepted — `RecordPurchasedEvent` omits `release_id` and `edition`.** Indexers join on `pressing_id` to `PressingCreatedEvent` (`pressing.move:60-67,134-140`). The README documents the join; events were deliberately slimmed.

No Open findings of Low severity or higher.

## Checked, no finding

- **Edition sequencing and uniqueness.** `edition > 0`, and for `edition > 1` the Release UID must hold `PressingKey(edition - 1)` (`pressing.move:76-84`); `derived_object::claim` aborts on a second claim of the same key. No `u16` underflow. Tests: `first_edition_cannot_be_skipped`, `intermediate_edition_cannot_be_skipped`, `predecessor_must_belong_to_the_same_release`, `maximum_edition_still_requires_its_predecessor`, `release_cannot_create_the_same_edition_twice`.
- **Supply cap and overflow.** `supply < max_supply` is asserted before the increment (`pressing.move:122-124`), so `supply` never exceeds `u32::MAX` and a failed press consumes no number (abort rolls back). `max_supply > 0` enforced; `u32::MAX` accepted. Tests cover boundary and post-rotation cap.
- **Derived-ID namespace.** `RecordKey`, `PressingKey` and `PressingAdminCapKey` have module-private constructors; a probe module that tried to build `RecordKey(1)` failed to compile (`EC04001`). `derived_object::derive_address` hashes the key type, so a foreign key type cannot collide. A Pressing admin with `uid_mut` therefore cannot pre-claim a Record number or a second admin cap.
- **Re-claim after delete.** Probe: destroy Record #1, then press again; the Pressing issues #2 and the address of #1 stays claimed.
- **Authorization checks.** `authorize` compares `cap.pressing_id` with the Pressing's own ID (`pressing.move:214-216`); a foreign cap with a matching `pressing_id` field cannot exist because the cap is derived once at creation. `type_name::with_defining_ids` ties Distributor identity to the defining package, surviving Distributor upgrades. Tests: mismatched Pressing cap and Release cap, foreign caps, revoked Distributor.
- **Witness consumption.** `press` takes the witness by value with `drop` and discards it (`pressing.move:117`); a `copy + drop` witness with a public constructor presses freely (probe), which is why the README forbids authorizing publicly constructible witnesses.
- **Object lifecycle.** `Pressing` is `key` only: no destructor, no transfer, no store, so the value returned by `new` can only be consumed by `share` (`pressing.move:111-113`). `PressingAdminCap` is `key + store` (free transfer). `Record` is `key + store`; framework transfer, wrapping, sharing and freezing all work; `destroy` is the only destructor.
- **Clock integrity.** `purchased_at_ms` comes from `&Clock`, which only exists as the system object outside tests (`record.move:102`).
- **Events.** Field sizes match the README's byte table (102/32/32/84/32). Distributor events fire only on set changes; sharing and view functions are silent (`pressing_event_tests`).
- **Limits.** One shared-object mutation and one dynamic-field creation per press; presses within one edition serialize on the Pressing. At most ~1,000 presses per PTB (command limit) and one event each, well under the 1,024-event limit. `VecSet<TypeName>` membership is linear; intended for a handful of Distributors.
- **README claims.** Checked against the code: no Registry/initializer; Pressings creatable before or after `release::publish` (`release::uid_mut` does not check state); `number` equals post-press supply; byte sizes; join keys.

## Operational requirements

- Custody each `PressingAdminCap`; it is `store` and freely transferable. Authorize the replacement Distributor before revoking the old one.
- Never authorize a Distributor witness that any module outside the Distributor can construct.
- Share the Pressing in the creating transaction; `new` is otherwise unusable.
- Detach extension fields before `record::destroy`.
- Derive IDs client-side: `pressing::derive_address(release_id, edition)`, `pressing::derive_admin_cap_address(pressing_id)`, `record::derive_address(pressing_id, number)`.

## Verification

- `sui move test --coverage`: 40/40 passed; `sui move coverage summary`: 100.00% for both modules (Sui 1.82.1).
- `sui move build -e mainnet` and `sui move build -e testnet`: both succeed.
- Throwaway probes (not committed): module-private key construction, public-witness press, destroy-then-press.
