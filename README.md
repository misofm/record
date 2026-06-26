# miso-record

The Miso record — an owned, ownable copy of a release, on Sui. A deliberately slim
core that gains all its functionality from extensions — the same slim-core +
raw-`&mut UID` model as `miso-player` and the miso-protocol.

```move
public struct Record has key, store { id: UID, release_id: ID, number: u32 }
```

That's the whole object. A `Record` is **owned** and **transferable**. Pressing /
edition logic, settings, statistics, vouchers, SEAL access — none of it lives in the
struct. Each is an extension package that attaches its own state to the record's
`UID` as a dynamic field.

## Design

- **Release by `ID` only.** The core stores the release's `ID`, not a typed `Release`,
  so it has **no dependency on the protocol**. Extensions that need the typed release
  bring that dependency themselves.
- **Authority is possession.** Only the owner can produce a `&mut Record`, so `uid_mut`
  is fully open — no capability, no allowlist:

  ```move
  public fun uid(self: &Record): &UID
  public fun uid_mut(self: &mut Record): &mut UID
  ```

- **Numbering/minting is an extension concern.** `new(release_id, number, ctx)` just
  constructs the struct; *who* may press which release and *how* `number` is assigned
  (per-release editions, etc.) belongs to a pressing extension, not the core.

## Layout

```
move/
  core/                miso_record — the slim Record (this package)
  extensions/          pressing, settings, statistics, vouchers, SEAL access … (to come)
```

Mirrors the protocol's `move/core` + `move/extensions` split.

## Build

```bash
cd move/core && sui move test
```

## Status

| Package | State |
|---|---|
| `miso_record` (core) | ✅ slim struct, builds, 1 test |

Extensions (pressing/editions, settings, statistics, vouchers, SEAL ACL) are the
next pieces — they'll live under `move/extensions/`. The previous monolithic
`miso_record` (record + pressing + settings + statistics + vouchers in one package,
in the `miso` monorepo) is the reference for what to break out.

License: Apache-2.0
