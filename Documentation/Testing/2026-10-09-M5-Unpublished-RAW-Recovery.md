# Native RAW recovery before sidecar publication — 2026-10-09

## Scope and source

Continuation branch: `t3code/continue-3-0-implementation-plan-1`, based on
merged `802c1c3`. Implementation commit: `8afe71b`. Checks ran before commit
with the three implementation/test Swift files modified; the report was untracked.
Only recovery-helper comment wording changed after compilation. No unrelated
source changes were present.

The isolated DEBUG hook can now select a publication boundary. Four new native
cases kill the app at `originalsHeld`, after the Sony ARW or Canon CR3 and its
XMP have moved into the actual transaction but before the replacement XMP is
visible. The prior `beforeCommit` cases remain regression coverage.

Explicit test-assisted reconciliation validates the entire original group,
requires unpublished destinations to remain absent, checks the staged replacement
against its snapshot, preserves it outside the output folder, restores originals
and retains the full transaction outside the admission scan. A later relaunch
cannot restore the old original a second time. This helper is DEBUG-only and is
not a production automatic-recovery feature.

## Environment and fixtures

macOS 27.0.1 (26A434), arm64, Xcode 27.0 (27A266a).
Apple Development signed isolated DEBUG app: 3.0.0 (44),
`build/continuation-tests/Build/Products/Debug/Aagedal FTP Sync.app`.
The app is re-signed and strictly verified after staging authorized disposable
RAW copies in its ignored Resources directory. Original user photos are not read
or changed by the app. No private media or manual-checklist observations are
committed.

Sony ARW SHA-256:
`4ceb7e1b59737362d0b3aa16fa04c3461f59bd4acb9e277be47eb61f054936dd`.
Canon EOS R1 CR3 SHA-256:
`c915aeb4a660f4030c37fb2a45e882bb20fc280c68316a6eb329ecf2988f0484`.
Sidecars are rich generated XMP, not original camera sidecars.

## Verification

The focused `LocalMatchingPublicationTests` suite executes 32 tests, with four
expected opt-in skips and zero failures (exit 0). Its added unpublished-pair
regression exercises 24 format/folder/defect combinations: successful recovery,
edited staged XMP, redirected staged XMP, competing XMP, competing RAW and an
unsupported interruption marker. Rejected recovery leaves holdings and manifest
intact, preserves competing files and creates neither rescue nor restored outputs.
Successful recovery preserves the staged replacement, RAW bytes/date and manifest
and is idempotent after a later sidecar edit.

Development identity, security baseline and `git diff --check` pass.
Signed UI build-for-testing passes (exit 0). All eight signed native cases pass,
with zero skips/failures in 304.657 seconds (exit 0): ARW and CR3 in both folder
modes at `originalsHeld`, plus the four existing `beforeCommit` regressions.
The earlier-boundary cases prove neither RAW nor replacement XMP is visible
while recovery is blocked. The staged XMP has the intended City and preserved
Unicode description, keywords, copyright, rating and unknown namespace attribute.
Cancel retains the transaction; explicit test-assisted recovery preserves both
choices; retry preflight is read-only; retry publishes one image with zero
failures; and a further relaunch suppresses processing through its current receipt.
RAW/source/holding/restored/retried bytes and final modification dates survive.

Result bundles in this worktree:

- `build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.09_21-00-02-+0200.xcresult`
- `build/continuation-tests/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.10.09_21-00-38-+0200.xcresult`

CUA desktop inventory returned successfully. A companion Photo Agent build and
unit-test run used separate derived-data roots; no other UI runner was active.
No companion application state was edited. This focused run does not count as
VoiceOver observation or a complete native smoke-suite pass.

Logs:

- `/private/tmp/aftpsync-held-raw-build.log`
- `/private/tmp/aftpsync-held-raw-unit.log`
- `/private/tmp/aftpsync-held-raw-ui.log`

## Reproduction

Use the existing smoke scheme and an isolated build directory. Supply the local
signing team through `DEVELOPMENT_TEAM`, reuse cached pinned dependencies if
needed, and stage only authorized copies as `UITestRecovery.arw` and
`UITestRecovery.cr3` in the DEBUG app Resources. Re-sign preserving the app's
entitlements, identifier, flags and runtime, then strictly verify its signature.
Never stage private media in a Release candidate.

```sh
xcodebuild build-for-testing -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/continuation-tests -disableAutomaticPackageResolution \
  DEVELOPMENT_TEAM=YOUR_LOCAL_TEAM
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/continuation-tests -disableAutomaticPackageResolution \
  DEVELOPMENT_TEAM=YOUR_LOCAL_TEAM \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests
# Stage/re-sign/verify AFTER any command that rebuilds the app.
TEST_RUNNER_AAGEDAL_NATIVE_RAW_RECOVERY=1 xcodebuild test-without-building \
  -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSyncUISmokeTests \
  -destination 'platform=macOS' -derivedDataPath build/continuation-tests \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  DEVELOPMENT_TEAM=YOUR_LOCAL_TEAM \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testCameraRawHeldOriginalsReconcileAndRetryAcrossRelaunch \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testManagedCameraRawHeldOriginalsReconcileAndRetryAcrossRelaunch \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testCanonRawHeldOriginalsReconcileAndRetryAcrossRelaunch \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testManagedCanonRawHeldOriginalsReconcileAndRetryAcrossRelaunch
```

The actual native invocation also selected the four corresponding
`testCameraRawPublicationReconcilesAndRetriesAcrossRelaunch`,
`testManagedCameraRawPublicationReconcilesAndRetriesAcrossRelaunch`,
`testCanonRawPublicationReconcilesAndRetriesAcrossRelaunch` and
`testManagedCanonRawPublicationReconcilesAndRetriesAcrossRelaunch` regressions.
Build and test invocations additionally used `-clonedSourcePackagesDirPath`
with the existing local pinned package cache. No package versions changed.

Without explicit opt-in, camera UI cases skip. Missing opted-in fixtures fail.

## Remaining gates

Prepared and partial-publication interruptions, original rich camera sidecars,
scoped Programming/conflict batches, ordinary-sync interruption, VoiceOver,
macOS 14 runtime, controlled enriched performance and complete signed Release
acceptance remain open. This slice leaves shipping recovery behavior, the tracked
Release candidate identity and private manual results unchanged. It does not close
M5 or establish release readiness.
