# miso-record

The Miso record — an owned, ownable copy of a release, on Sui. A deliberately slim
core that gains all its functionality from extensions — the same slim-core +
raw-`&mut UID` model as `miso-player` and the miso-protocol.

```move
public struct Record has key, store {
    id: UID,
    release_id: ID,
    created_at_ms: u64,   // stamped off the Clock at mint — never supplied by the minter
}
```

That's the whole object — only what is fixed at birth, true forever, and meaningful
without a namespace. A `Record` is **owned** and **transferable**. Serial numbers,
sale terms, statistics, playtime, vouchers, SEAL access — none of it lives in the
struct. Each is an extension package that attaches its own state to the record's
`UID` as a dynamic field: the serial certificate and purchase receipt are
`miso_pressing`'s, because a serial is only meaningful inside the sequence that issued
it — two sale packages for the same release each count from 1, so "copy 42" is
always "copy 42 *of this pressing*", never a bare 42.

## Design

- **Release by `ID` only.** The core stores the release's `ID`, not a typed `Release`,
  so it has **no dependency on the protocol**. Extensions that need the typed release
  bring that dependency themselves.

- **Minting is authorized by type; sale mechanics live in their own packages.** A
  record only comes into being through `record::mint`, which requires a *witness*
  whose **type** is on the `Settings` allowlist:

  ```move
  public fun mint<W: drop>(_w: W, settings: &Settings, parent: &mut UID, release_id: ID, number: u64, clock: &Clock, ctx): Record
  ```

  `Settings` (shared) holds a `VecSet<TypeName>` of authorized minter witnesses,
  managed by a `SettingsAdminCap`. A sale package defines its own witness, mints it
  only on its paid path, and hands it to `mint`; the check is a runtime `TypeName`
  lookup, never a compile-time dependency on the sale package. **A brand-new sale
  package plugs in with zero redeploy of this package** — an admin just authorizes its
  witness type. This is why the sale lives in its own package
  ([`miso-pressing`](https://github.com/misonetwork/miso-pressing), package `miso_pressing`,
  witness `miso_pressing::pressing::MintWitness`): same `Record`, different shops,
  different sale mechanics.

- **Every record derives off its minting context.** `mint` claims the record's UID off
  a `parent: &mut UID` (e.g. a `Pressing`'s UID) keyed by `RecordKey(number)`, so every
  copy is deterministically addressable from its parent and a claim slot can be minted
  at most once per parent. The record does not *store* the number — the core keeps
  serials as pure addressing (`derive_id(parent, number)` recomputes and thereby
  verifies the linkage); the readable serial is the issuing package's dynamic field.
  There is deliberately no fresh-UID mint: a gifting or airdrop package derives off an
  object of its own.

- **Otherwise, authority is possession.** Once a record exists, only the owner can
  produce a `&mut Record`, so `uid_mut` is fully open — no capability, no allowlist:

  ```move
  public fun uid(self: &Record): &UID
  public fun uid_mut(self: &mut Record): &mut UID
  ```

## Proving access (`miso_record_access`)

Gated material — a recording's stems, a mixer session — is opened against a proof,
not a lookup. `miso_record_access::access` holds the dry-run targets: a verifier
simulates one with the claimed wallet as sender, and success *is* the authorization.

```move
entry fun prove_release(record: Record, release: &Release, ctx: &TxContext)
entry fun prove_recording(record: Record, release: &Release, recording_id: ID, ctx: &TxContext)
entry fun prove_composition<RecordingShare, CompositionShare>(
    record: Record,
    release: &Release,
    recording: &Recording<RecordingShare, CompositionShare>,
    composition: &Composition<CompositionShare>,
    ctx: &TxContext,
)
```

**The package is named for the credential; each entry is named for the subject.**
The credential never varies — every proof starts from a `Record`. What varies is
what is being opened. New subjects join as new entries, not new packages.

| Entry | Gates | Links |
|---|---|---|
| `prove_release` | liner notes, cover art pack, a whole-album session | 1–2 |
| `prove_recording` | a track's stems, its mixer session | 1–3 |
| `prove_composition` | material on the written work — lyrics, notation | 1–4 |

Four links, and Sui enforces the first one itself:

1. **wallet → record.** The `Record` is taken **by value** and handed back to the
   sender, so the fullnode's input checker has already verified the sender owns it.
   By-value is the whole security argument — `&Record` would be a hole, because
   `Record` has `store` and a shared object is a legal `&` input for *any* sender.
   By value rejects shared inputs (they cannot be transferred out) and immutable ones
   (they cannot be passed by value).
2. **record → release.** `record.release_id() == release.id()`. `prove_release`
   stops here.
3. **release → recording.** `release.contains_recording(recording_id)`.
   `prove_recording` stops here.
4. **recording → composition.** Not a runtime assert — a recording carries its
   composition as the `CompositionShare` *phantom type*, never a stored id, so
   `Recording<_, C>` and `Composition<C>` only type-check together. The 1:1
   share-type↔object invariant (`share::initialize` consumes the `TreasuryCap`)
   is what makes that a proof. The `composition` argument is read by no line of
   the function — it is there so the verifier names the composition it gates **by
   object id**, rather than lifting the type argument off the recording, which
   would make the check vacuously true and fail open in silence.

> **Simulate with transaction checks ENABLED** — `dryRun`, or gRPC
> `SimulateTransaction` with `checks` unset. `devInspect` defaults to
> `skipChecks: true`, which skips the owner check entirely and would let any sender
> name any record. Link 1 is the one link this package does not implement, so losing
> it is silent.

Executed for real each entry is a self-transfer no-op. The link checks are exposed
as `assert_grants_release` / `assert_grants_recording` / `assert_grants_composition`
so a later custody shape — the `miso-player` record shelf, a Seal `seal_approve_*`
policy — reuses them rather than restating the rule.

A recording may sit on several releases and a composition may be recorded many
times, so `prove_composition` says the listener owns *a* recording of the written
work, not every recording of it. Where that is too broad, gate with
`prove_recording`.

## Layout

```
move/
  sources/record.move     the slim Record
  sources/settings.move   Settings — the witness-type mint allowlist
  tests/record_tests.move
extensions/
  miso_record_access/     prove a record grants access to a recording
```

The V1 sale — the `Pressing` — lives in its own repo:
[`miso-pressing`](https://github.com/misonetwork/miso-pressing). A second sale mechanic
(auction, dutch, giveaway…) would be another sibling package, each authorized by its
own witness type in `Settings`.

## Build

```bash
cd move && sui move test
cd extensions/miso_record_access && sui move test
```

## Status

| Package | State |
|---|---|
| `miso_record` | ✅ slim struct + `Settings` witness-gated mint, 4 tests |
| `miso_record_access` | ✅ release / recording / composition dry-run proofs, 9 tests — not yet published |

Further extensions (statistics, vouchers, SEAL ACL) attach to a record's `UID` and are
the next pieces.

License: Apache-2.0
