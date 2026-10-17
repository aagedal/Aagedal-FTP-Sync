# Native prepared and first-publication RAW recovery — 2026-10-17

## Scope

Continuation branch: `t3/continue-plan`, based on merged `d2f0783`.
Implementation commit: `c460ddc`. Tests ran before commit with only the three
implementation/test Swift files modified and this report untracked. No source
changes followed the final build and test runs.
Only DEBUG fixture reconciliation and tests change. Shipping recovery behavior,
the tracked Release candidate and private manual acceptance remain unchanged.
No local checklist results file was present in this worktree.

The isolated native suite now selects `prepared` and `published-0` for Sony ARW
and Canon EOS R1 CR3 in ordinary and managed destinations. At `prepared`, the
actual manifest and staged replacement exist, but both originals remain visible
and no holdings exist. The test-assisted helper validates the complete pair
against source and snapshots, rejects unexpected holdings and preserves originals
in place without rewriting their bytes, inode or dates. It rescues the staged
replacement and retains the transaction outside recovery admission.

At `published-0`, the replacement XMP is visible while the RAW and original XMP
remain held. This is the first/only replacement in a one-image transaction;
it does not establish interruption across multiple image transactions or a
partially published multi-output batch.

## Fixtures and environment

arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a).
Isolated Apple Development signed DEBUG app: 3.0.0 (44),
`build/continuation-tests/Build/Products/Debug/Aagedal FTP Sync.app`.
Previously authorized disposable RAW copies were copied from an earlier ignored
DEBUG app bundle, then the new app was re-signed and strictly verified.
No original user photos or companion application state were changed.

Sony ARW SHA-256:
`4ceb7e1b59737362d0b3aa16fa04c3461f59bd4acb9e277be47eb61f054936dd`.
Canon CR3 SHA-256:
`c915aeb4a660f4030c37fb2a45e882bb20fc280c68316a6eb329ecf2988f0484`.
Sidecars are rich generated XMP, not original camera sidecars.

## Verification

The focused `LocalMatchingPublicationTests` suite executes 33 tests with four
expected opt-in skips and zero failures (exit 0). The new prepared regression
covers 40 format/folder/defect combinations: successful preservation, RAW/XMP
edits, redirected RAW, unexpected holding, changed/redirected stage, changed
snapshot/source and unsupported phase. Rejected operations preserve originals'
bytes, inode and dates, retain the manifest, and create no rescued publication
or reconciled directory. Successful operations preserve staged output and manifest,
retain originals' inode/dates and remain idempotent.

Development identity, security baseline and `git diff --check` pass.
The signed native build-for-testing passes (exit 0). A final focused hosted rerun
after helper cleanup also passes 33 tests with four opt-in skips and no failures.
The built app passes the bundled AuraFace verifier.
The first eight-case native invocation exited 65 before executing tests:
`Timed out while enabling automation mode.` Desktop accessibility inspection
subsequently returned the T3 window, but took 824 seconds despite a requested
15-second timeout. A one-case native retry then passed the Sony prepared case
in 40.961 seconds (exit 0), confirming recovery/retry/relaunch and original
identity preservation. The final combined selection passes all 16 signed native cases with zero skips
or failures in 642.781 seconds (exit 0). It covers both formats and folder modes
at `prepared`, `originalsHeld`, `published-0` and `beforeCommit`. Recovery admission
blocks processing; cancellation retains evidence; explicit test-assisted
reconciliation retains originals and replacement; retry preflight is read-only;
retry publishes one image with no failures; a further relaunch retains current
receipt idempotence. RAW bytes/dates and rich XMP description, keywords,
copyright, rating and unknown namespace attribute survive. Prepared cases
additionally verify unchanged original inode/dates and retained stage bytes/date;
all phases verify expected visible/staged file presence.

The first restricted Xcode attempt failed because package/compiler caches were
outside writable roots. The approved build used the existing pinned package
cache; no dependency versions changed. Desktop inventory succeeded before UI
work. Concurrent Media Player build and Media Converter unit tests used separate
build roots; no other UI runner was observed.

Logs: `/private/tmp/aftpsync-boundary-unit.log`,
`/private/tmp/aftpsync-boundary-build.log`, `/private/tmp/aftpsync-boundary-ui.log`,
`/private/tmp/aftpsync-boundary-ui-retry.log`,
`/private/tmp/aftpsync-boundary-unit-final.log`,
`/private/tmp/aftpsync-boundary-build-final.log`,
`/private/tmp/aftpsync-boundary-ui-final.log`.
Hosted result:
`build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.17_16-40-55-+0200.xcresult`.

Final hosted result:
`build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.17_16-58-52-+0200.xcresult`.
Final native result:
`build/continuation-tests/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.10.17_16-59-34-+0200.xcresult`.
Initial initialization-failure result:
`build/continuation-tests/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.10.17_16-42-39-+0200.xcresult`.
Successful single-case retry:
`build/continuation-tests/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.10.17_16-57-57-+0200.xcresult`.

An independent read-only reviewer found no blocking source issue. Its suggested
native inode/date and retained-stage assertions were incorporated; a latent
non-RAW prepared-helper assumption was corrected before the final build.
This focused selection is not a complete UI smoke-suite or VoiceOver pass.

## Reproduction

Use the build, staging and re-signing procedure in
[the earlier RAW report](2026-10-09-M5-Unpublished-RAW-Recovery.md), with this
worktree's `build/continuation-tests` derived-data directory. Run the focused
hosted selection with scheme `AagedalFTPSync`. Build the UI smoke scheme, stage
only authorized disposable `UITestRecovery.arw` and `UITestRecovery.cr3` copies,
re-sign and strictly verify before `test-without-building`.

Set `TEST_RUNNER_AAGEDAL_NATIVE_RAW_RECOVERY=1`, disable parallel UI testing, and
select these eight new methods from `AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests`:

- `testCameraRawPreparedReconcileAndRetryAcrossRelaunch`
- `testManagedCameraRawPreparedReconcileAndRetryAcrossRelaunch`
- `testCanonRawPreparedReconcileAndRetryAcrossRelaunch`
- `testManagedCanonRawPreparedReconcileAndRetryAcrossRelaunch`
- `testCameraRawFirstPublishedReconcileAndRetryAcrossRelaunch`
- `testManagedCameraRawFirstPublishedReconcileAndRetryAcrossRelaunch`
- `testCanonRawFirstPublishedReconcileAndRetryAcrossRelaunch`
- `testManagedCanonRawFirstPublishedReconcileAndRetryAcrossRelaunch`

The final invocation also selected all eight existing `Publication` and
`HeldOriginals` RAW regressions in that test class.
Without explicit opt-in these camera UI cases skip; opted-in missing fixtures fail.
Never stage private media in a Release candidate.

## Remaining gates

Original rich camera sidecars, scoped Programming/conflict batches, ordinary-sync
interruption, VoiceOver, macOS 14 runtime, controlled enriched performance and
complete signed Release acceptance remain open. This is current-host DEBUG
evidence, not a closed M5 milestone or readiness for user acceptance.
