# Witness-authorized Record

> **2026-08-31 — current direction.** `Record<Certificate>` is replaced by one
> concrete `Record`. Miso Record is the distribution format, so creation is governed
> by a shared `miso_record::settings::Settings` allowlist rather than delegated to
> arbitrary certificate specializations.

## Core

- [x] Add shared `Settings` with a `VecSet<TypeName>` of authorized witness types.
- [x] Create and share Settings from `init`; transfer `SettingsAdminCap` to the
      publisher.
- [x] Add idempotent `authorize<W>`, `revoke<W>`, `is_authorized<W>`, enumeration,
      and lifecycle events.
- [x] Replace `Record<Certificate>` with concrete key-only `Record { id, release_id }`.
- [x] Replace open `record::new` with `record::mint<W: drop>`, requiring `&Settings`
      and consuming an authorized witness.
- [x] Keep derived-only creation: every Record is claimed from a distribution parent
      and `u64` number.
- [x] Include the creating witness `TypeName` in `RecordCreatedEvent`.
- [x] Keep address transfer and extension UID access; expose no share or freeze path.
- [x] Cover authorization, revocation, idempotence, shared initialization,
      deterministic IDs, collision rejection, extensions, and transfer in tests.

## Primitive-library decision

Keep the allowlist inside `miso_record::settings` until a second consumer needs the
same semantics. Existing neighboring witness systems are similar but not identical:
Vault authorization is per-vault and typed-dynamic-field based, while Audio records
witness provenance without an allowlist.

If the exact policy repeats, extract only a non-object
`TypeAllowlist<phantom Scope>` primitive. Its constructor should require
`std::internal::Permit<Scope>` so only the scope's defining module can instantiate
that policy domain. Each consumer should retain its own Settings object, admin cap,
events, and initialization rather than sharing one global authorization object.

## Integration follow-ups

- [ ] Update `miso_pressing` to replace its certificate with a package-controlled
      `Witness() has drop` and call witness-gated `record::mint`.
- [ ] Update downstream `miso_record` Git dependencies to remove `subdir = "move"`.
- [ ] Authorize the pressing witness in the newly published Settings object.
- [ ] Update `miso_record_seal_policy` from `Record<Certificate>` to concrete
      `Record`.
- [ ] Fresh-publish `miso_record`; this is incompatible with the certificate layout.
