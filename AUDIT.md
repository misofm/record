# Security Review — `miso_record`

**Revision:** working tree · **Date:** 2026-08-31 · **Toolchain:** Sui 1.78.1

Review of the concrete, key-only `Record`, its derived-object creation path, and the
shared witness allowlist. Verdict: **safe — no findings.**

## Security model

- `settings::init` creates the only production `Settings`, shares it, and transfers
  its `SettingsAdminCap` to the publisher (`settings.move:49-65`).
- `settings::authorize<W>` and `revoke<W>` are the only allowlist mutation paths and
  both require that cap (`settings.move:70-95`).
- `record::mint<W: drop>` consumes a witness and aborts unless its defining
  `TypeName` is present in Settings (`record.move:66-86`).
- Every Record ID is claimed from `(parent, RecordKey(number))`, making creation
  deterministic and claim-once per parent and number (`record.move:74-77`).
- `Record` has `key` without `store`, so external packages cannot transfer, share,
  freeze, or wrap it with framework `public_*` functions (`record.move:29-33`).

## Checks performed

- **Record construction is closed.** `Record` fields are module-private and the only
  public constructor is witness-gated `mint`. There is no raw constructor or generic
  `Record<Certificate>` specialization that another package can create.
- **Settings construction is closed.** The production constructor is private and is
  reached only from module `init`; arbitrary callers cannot create a permissive
  Settings object and pass it to `mint`.
- **Administration is capability-gated.** Callers cannot construct
  `SettingsAdminCap`; possessing the cap is required for every allowlist mutation.
  Authorization and revocation are idempotent and emit one event only when state
  changes.
- **Witness identity is exact.** Membership uses
  `type_name::with_defining_ids<W>()` at both authorization and mint, so a freshly
  published package's identically named witness is a different authority and must be
  authorized separately.
- **Witness values are consumed.** `W: drop` lets a distribution module hand a
  short-lived witness directly to `mint`; when the authorized type has only `drop`,
  that witness cannot be copied or stored.
- **Read-only Settings avoids a mint bottleneck.** Minting takes `&Settings`, not
  `&mut Settings`; shared-object reads can execute concurrently. Registry mutations
  remain consensus-sequenced as intended.
- **Derived-ID uniqueness holds.** `derived_object::claim` rejects a second claim for
  the same parent and number. Different parents or numbers produce distinct,
  precomputable addresses.
- **Ownership remains direct.** The core exposes address transfer and destruction but
  no share or freeze path. Missing `store` prevents an external bypass.
- **Extension authority remains possession-based.** `uid_mut` is open, but only a
  caller able to provide `&mut Record` can attach or change dynamic fields.

## Operational requirement

The Settings admin must authorize only witness types whose construction policy is
appropriate. The recommended witness has only `drop` and a package-private
constructor. Authorizing a primitive, copyable type, or publicly constructible
witness would intentionally grant creation to everyone able to produce that value.

The `SettingsAdminCap` should be held by Miso governance or a suitable capability
vault. Loss prevents future authorization changes; compromise permits arbitrary
witness types to be authorized.

## Verification

Nine Move unit tests cover authorized minting, unauthorized and revoked witnesses,
idempotent allowlist events, shared initialization, claim collisions, distinct and
precomputable derived IDs, dynamic-field extension access, destruction, and
key-only address transfer.
