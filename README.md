# miso-record

The Miso Record is an owned copy of a release on Sui. It is Miso's distribution
format: every `Record` is created by a distribution mechanism that Miso has explicitly
authorized.

```move
public struct Record has key {
    id: UID,
    release_id: ID,
}
```

There is one concrete Record type. Issuance details are not embedded as a generic
certificate, and arbitrary packages cannot create alternate Record specializations.

## Creation policy

`miso_record::settings::Settings` is a shared allowlist of distribution witness
types. Its `SettingsAdminCap` authorizes changes to that list:

```move
settings.authorize<miso_pressing::witness::Witness>(&settings_admin_cap);
settings.revoke<miso_pressing::witness::Witness>(&settings_admin_cap);
```

An authorized distribution package controls construction of its witness:

```move
module miso_pressing::witness;

public struct Witness() has drop;

public(package) fun new(): Witness {
    Witness()
}
```

Its distribution path consumes that witness when minting:

```move
let record = record::mint(
    pressing.uid_mut(),
    settings,
    witness::new(),
    release_id,
    number,
);
```

`mint` reads the shared Settings through `&Settings`, so Record creation does not
mutate or serialize on the registry. Only the rare `authorize` and `revoke` operations
need `&mut Settings`.

Authorization is a governance boundary: the admin must authorize only witness types
whose constructors are suitably restricted. A witness should normally have only the
`drop` ability and a package-private constructor.

## Record identity

Every Record UID is derived from its distribution parent and a `u64` claim number.
The pair `(parent, number)` is unique and its address can be computed before minting:

```move
let expected = record::derive_address(parent_id, number);
```

The number belongs to the distribution's namespace; it is emitted at creation but is
not stored in the Record. The only universal Record fact is the copied release ID.

## Ownership and extensions

`Record` deliberately has `key` without `store`. External packages cannot use
`public_transfer`, share, freeze, or wrap it. The module exposes address transfer but
no sharing or freezing path, preserving the direct-ownership invariant used by Seal
policies.

Possession governs extensions. A holder can provide `&mut Record`, so extensions can
attach their own dynamic fields through:

```move
public fun uid(self: &Record): &UID
public fun uid_mut(self: &mut Record): &mut UID
```

Callers must detach extensions before destroying a Record or those dynamic fields
become inaccessible.

## Events

| Event | Facts |
|---|---|
| `RecordCreatedEvent` | Record, distribution parent, release, claim number, witness type |
| `RecordDestroyedEvent` | Record, release |
| `SettingsCreatedEvent` | Settings and admin-cap IDs |
| `WitnessAuthorizedEvent` | Settings and authorized witness type |
| `WitnessRevokedEvent` | Settings and revoked witness type |

## Why Settings stays local

The reusable-looking mechanism is intentionally local to this package for now. The
current neighboring witness policies have different semantics: some are per-object,
some require witness participation during authorization, and some record provenance
without an allowlist. Extracting a published primitive prematurely would add a hard
package dependency without a proven common contract.

If another layer needs this exact policy, the extraction boundary is a non-object
`TypeAllowlist<phantom Scope>` guarded at construction by
`std::internal::Permit<Scope>`. Each domain should continue to own its Settings
object, admin capability, lifecycle, and events.

## Layout

```text
Move.toml
sources/
  record.move
  settings.move
tests/
  record_tests.move
```

## Build

```bash
sui move test
```

This architecture is incompatible with the previously published
`Record<Certificate>` package and requires a fresh publication. Distribution and
Seal-policy packages must update to the concrete `Record` type and witness-gated
`record::mint` API. Git dependencies should target the repository root rather than
using `subdir = "move"`.

License: Apache-2.0
