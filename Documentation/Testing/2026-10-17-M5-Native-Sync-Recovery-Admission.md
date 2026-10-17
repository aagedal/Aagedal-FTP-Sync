# Native Sync Now recovery admission — 2026-10-17

## Scope and source

Continuation branch: `t3/continue-plan-3`, based on merged `91f14b5`.
Only native UI test source and acceptance documentation change. No private local
checklist observations file was present in this worktree.

Four opt-in camera RAW cases extend the real single-image reprocessing SIGKILL
fixture with ordinary **Sync Now** admission and resume. Sony ARW and Canon EOS R1
CR3 each run in ordinary and managed destinations. The crash occurs at
`beforeCommit` during explicit reprocessing, not during ordinary sync publication.
This distinction is necessary: ordinary sync uses a different endpoint import
path and the existing matching-publication crash hook does not reach it.

After relaunch, two ordinary Sync Now attempts must each record a new failure
and expose the retained transaction path. Recovery directory membership,
retained/visible/source bytes, modification dates and inodes remain unchanged;
processing audit and download-manifest bytes remain unchanged, and neither
ordinary nor processed RAW/XMP outputs appear. Existing explicit test-assisted
reconciliation preserves both choices, then the existing native reprocess retry
and receipt-idempotence checks run.

A subsequent ordinary Sync Now transfers the separate source pair into the
non-nested destination path, preserving RAW bytes/dates and rich generated XMP
while resolving City. Managed jobs also verify their Processed Files copy and
source removal after successful sync; ordinary jobs retain source bytes. A relaunch and idle ordinary
run must report zero transfers and preserve all published bytes, dates and
inodes. The retained manifest and rescued XMP remain available.

This does not claim audit receipt-count stability from the idle run. It verifies
absence of output republication. Reconciliation remains an explicit DEBUG test
helper, not a shipping automatic-recovery feature.

## Environment and fixtures

arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a).
Apple Development signed isolated DEBUG app, 3.0.0 (44):
`build/continuation-tests/Build/Products/Debug/Aagedal FTP Sync.app`.
Previously authorized disposable bundle copies were staged and the app re-signed
and strictly verified. Original photos and companion app state were not changed.

Sony ARW SHA-256:
`4ceb7e1b59737362d0b3aa16fa04c3461f59bd4acb9e277be47eb61f054936dd`.
Canon CR3 SHA-256:
`c915aeb4a660f4030c37fb2a45e882bb20fc280c68316a6eb329ecf2988f0484`.
Sidecars are generated rich XMP, not original camera sidecars.

## Verification

The final selected signed native invocation passes all six cases with zero
failures or skips in 383.714 seconds, exit 0. It includes the four new ARW/CR3
ordinary-sync cases and both existing generated-JPEG interruption regressions.
The ordinary ARW case also passed an initial isolated run (77.777 seconds).
All assertions use the final compiled Swift source; no subsequent Swift changes
were made. Source was based on `91f14b5` with the UI test file modified and this
report untracked during verification; readiness/plan documentation followed.

Focused hosted suites pass 67 tests with five expected opt-in skips and zero
failures (exit 0): 34 activated-metadata integration cases and 33 local matching
publication cases. Signed build-for-testing, strict signature verification,
development identity, security baseline, bundled AuraFace verification and
whitespace checks pass. Independent read-only source and report reviews found
no blocking issue; additional filesystem-evidence assertions and more precise
source-removal wording were incorporated.

Desktop inventory succeeded. Photo Agent hosted tests and a Media Player native
run were active during preparation. The final UI run waited until the Media
Player test process exited, then ran 23:36–23:42 CEST. An attempted cross-thread
coordination message was rejected by automatic approval review because it would
steer unrelated work; no message was delivered and no other task was controlled.
The safer alternative was to finish hosted checks and wait for that native run
to exit. The first isolated ARW run had already completed successfully. No other
app was controlled. This is a selected native XCUITest pass, not a full smoke
suite, separate CUA workflow observation or VoiceOver acceptance pass.

Logs:

- `/private/tmp/aftpsync-sync-now-build.log`
- `/private/tmp/aftpsync-sync-now-build-final.log`
- `/private/tmp/aftpsync-sync-now-ui-first.log`
- `/private/tmp/aftpsync-sync-now-hosted.log`
- `/private/tmp/aftpsync-sync-now-ui-final.log`

Hosted result:
`build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.17_23-35-24-+0200.xcresult`.
Final native result:
`build/continuation-tests/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.10.17_23-36-18-+0200.xcresult`.
Xcode may prune older result bundles; text logs retain the initial isolated run.

## Reproduction

Follow the isolated build, authorized fixture staging and re-signing procedure
in [the earlier RAW report](2026-10-09-M5-Unpublished-RAW-Recovery.md).
Use this worktree's `build/continuation-tests` derived-data directory and the
existing pinned dependency cache. Set `TEST_RUNNER_AAGEDAL_NATIVE_RAW_RECOVERY=1`,
disable parallel testing and run `test-without-building` with the UI smoke
scheme. Select under `AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests`:

- `testSyncNowRejectsInterruptedCameraRawAndResumesAfterRecovery`
- `testManagedSyncNowRejectsInterruptedCameraRawAndResumesAfterRecovery`
- `testSyncNowRejectsInterruptedCanonRawAndResumesAfterRecovery`
- `testManagedSyncNowRejectsInterruptedCanonRawAndResumesAfterRecovery`

Missing opted-in media fails; without explicit opt-in these cases skip. Never
stage private media in Release.

## Limits and remaining gates

The normal sync path is left-to-right local-to-local. Reverse-direction and
metadata-disabled admission, custom processed folders, SIGKILL during ordinary
publication, multi-image selected-clip partial publication, original camera
sidecars, native production recovery UX, macOS 14, VoiceOver, controlled enriched
performance, companion native interchange and complete signed Release acceptance
remain open. The historical candidate stays IMPLEMENTING; this focused DEBUG
slice does not close M5 or establish readiness for user acceptance.
