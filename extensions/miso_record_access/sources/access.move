// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Proof that a wallet holds a `Record` granting access to gated material.
///
/// One question, answered by dry run: *may this sender open this?* A verifier
/// simulates one of the `prove_*` entries with the claimed wallet as sender, and
/// success **is** the authorization.
///
/// **The package is named for the credential; each entry is named for the
/// subject.** The credential never varies — every proof here starts from a
/// `Record`, the only thing a listener holds. What varies is what is being
/// opened:
///
/// | Entry | Gates | Links |
/// |---|---|---|
/// | `prove_release` | liner notes, cover art pack, a whole-album session | 1–2 |
/// | `prove_recording` | a track's stems, its mixer session | 1–3 |
/// | `prove_composition` | material on the written work — lyrics, notation | 1–4 |
///
/// New subjects join as new entries, not as new packages.
///
/// Every proof is a chain of links, and Sui enforces the first one itself:
///
/// 1. **wallet → record.** The `Record` is taken BY VALUE and handed straight
///    back to the sender. By-value is the entire security argument, and
///    `&Record` would be a hole: `Record` has `store`, so anyone may
///    `public_share_object` one, and a shared object is a legal `&` input for
///    *any* sender. Taken by value it rejects shared inputs (a shared object
///    cannot be transferred out) and immutable ones (an immutable object cannot
///    be passed by value), which leaves exactly one case — the sender owns it,
///    which the fullnode's input checker verified before execution began.
/// 2. **record → release.** The record is a copy of the release presented.
///    `prove_release` stops here.
/// 3. **release → recording.** That release has a track for the recording.
///    `prove_recording` stops here.
/// 4. **recording → composition.** The recording is a recording *of* that
///    composition. Unlike links 2 and 3 this one is **not a runtime assert**: a
///    recording carries its composition as the `CompositionShare` phantom type,
///    never as a stored id (`miso::recording`, module doc), so the link is
///    discharged by the type checker — see `assert_grants_composition`.
///
/// **The verifier must simulate with transaction checks ENABLED** — `dryRun`,
/// or gRPC `SimulateTransaction` with `checks` unset (it defaults to enabled).
/// `devInspect` defaults to `skipChecks: true`, which skips the owner check
/// entirely and would let any sender name any record. Link 1 is the one link
/// this module does not implement, so losing it is silent.
///
/// Because a dry run reports only success or failure, this module leaves nothing
/// to inference: it aborts with `#[error]` constants, so the simulation's error
/// carries a readable reason a verifier can log. Note that `#[error]` abort codes
/// embed the source line, so off-chain code must treat them as diagnostics and
/// branch only on success/failure.
///
/// Executed for real, every entry here is a self-transfer no-op, so they are
/// harmless to leave callable on chain.
///
/// A recording may appear on more than one release (a single and an album), and
/// a composition may be recorded many times. A record for *any* release carrying
/// a qualifying track grants access — access is scoped to the subject, not to the
/// release the listener happened to buy it on.
module miso_record_access::access;

use miso::composition::Composition;
use miso::recording::Recording;
use miso::release::Release;
use miso_record::record::Record;

// === Errors ===

#[error]
const EWrongRelease: vector<u8> = b"Record is not a copy of this release";

#[error]
const ERecordingNotOnRelease: vector<u8> = b"Release has no track for this recording";

// === Public Functions ===

/// Assert that `record` is a copy of `release` — link 2 on its own. Composable
/// by any package that has already established who holds the record: a later
/// player shelf, a Seal `seal_approve_*` policy.
public fun assert_grants_release(record: &Record, release: &Release) {
    assert!(record.release_id() == release.id(), EWrongRelease);
}

/// Assert that `record` grants access to `recording_id` — links 2 and 3: the
/// record is a copy of `release`, and `release` carries a track for that
/// recording.
public fun assert_grants_recording(record: &Record, release: &Release, recording_id: ID) {
    assert_grants_release(record, release);
    assert!(release.contains_recording(recording_id), ERecordingNotOnRelease);
}

/// Assert that `record` grants access to the composition `recording` is a
/// recording *of* — links 2, 3 and 4.
///
/// **Link 4 is discharged by the type checker, not by a line of this function.**
/// `Recording<_, CompositionShare>` and `Composition<CompositionShare>` can only
/// be passed together when they share the composition's share type, and
/// `miso_share::share::initialize` asserts zero supply and consumes the
/// currency's `TreasuryCap`, so a share type belongs to exactly one object. That
/// 1:1 invariant is what makes the shared phantom a proof rather than a hint.
///
/// `composition` is therefore read by no statement here — its *type* is the
/// assertion. It is a parameter anyway so that the verifier names the composition
/// it is gating **by object id**. Passing only the type argument would work
/// identically, and would invite a verifier to lift `CompositionShare` off the
/// recording's own type — which makes the check vacuously true and fails open in
/// silence.
public fun assert_grants_composition<RecordingShare, CompositionShare>(
    record: &Record,
    release: &Release,
    recording: &Recording<RecordingShare, CompositionShare>,
    _composition: &Composition<CompositionShare>,
) {
    assert_grants_recording(record, release, recording.id());
}

// === Dry Run Targets ===

/// Prove that the sender holds a copy of `release`. Gates release-scoped
/// material.
///
/// Private `entry` on purpose: a PTB cannot pass an entry function the *result*
/// of a public call, so no one can conjure a `Record` mid-transaction and feed
/// it in — it must be a direct owned-object input, which is what makes link 1
/// hold. The same applies to `prove_recording`.
entry fun prove_release(record: Record, release: &Release, ctx: &TxContext) {
    assert_grants_release(&record, release);
    transfer::public_transfer(record, ctx.sender())
}

/// Prove that the sender holds a record granting access to `recording_id`. Gates
/// recording-scoped material.
entry fun prove_recording(
    record: Record,
    release: &Release,
    recording_id: ID,
    ctx: &TxContext,
) {
    assert_grants_recording(&record, release, recording_id);
    transfer::public_transfer(record, ctx.sender())
}

/// Prove that the sender holds a record reaching `composition`, through a
/// recording of it that sits on `release`. Gates composition-scoped material.
///
/// Note what this does and does not say: it proves the listener owns *a*
/// recording of the written work, not that they own every recording of it. If
/// composition-scoped material should only open to a particular recording's
/// owners, gate it with `prove_recording` instead.
entry fun prove_composition<RecordingShare, CompositionShare>(
    record: Record,
    release: &Release,
    recording: &Recording<RecordingShare, CompositionShare>,
    composition: &Composition<CompositionShare>,
    ctx: &TxContext,
) {
    assert_grants_composition(&record, release, recording, composition);
    transfer::public_transfer(record, ctx.sender())
}

// === Test Only ===

/// The `prove_*` entries are private (uncallable from other modules), so tests
/// go through these wrappers.
#[test_only]
public fun prove_release_for_testing(record: Record, release: &Release, ctx: &TxContext) {
    prove_release(record, release, ctx)
}

#[test_only]
public fun prove_recording_for_testing(
    record: Record,
    release: &Release,
    recording_id: ID,
    ctx: &TxContext,
) {
    prove_recording(record, release, recording_id, ctx)
}

#[test_only]
public fun prove_composition_for_testing<RecordingShare, CompositionShare>(
    record: Record,
    release: &Release,
    recording: &Recording<RecordingShare, CompositionShare>,
    composition: &Composition<CompositionShare>,
    ctx: &TxContext,
) {
    prove_composition(record, release, recording, composition, ctx)
}
