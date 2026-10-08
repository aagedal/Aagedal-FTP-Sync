# Canon RAW and rich XMP native recovery — 2026-10-08

## Scope

Continuation branch: `t3code/continue-3-0-implementation-plan`, based on merged `f4e9ce4`.
Implementation commit: `eee56f1`. Checks ran against its source content before
commit with the listed implementation/test files modified; the evidence report
was untracked during testing. No unrelated source changes were present.
This slice extends the isolated DEBUG interruption fixtures and acceptance tests.
Shipping processing/recovery behavior, the historical Release candidate and the
private manual-checklist results are unchanged.

The camera fixture selector accepts only ARW or CR3. The explicit reconciliation
helper validates the selected format against the complete transaction path map
before writing either member. Synthetic regression coverage exercises both camera
extensions and both output folder modes, including changed sources, edited XMP,
a competing RAW destination, redirected holdings and incorrect/unsafe extension
requests. Both recovery choices remain outside the output folder after retry.

The generated valid XMP now contains Unicode description, two keywords,
copyright, rating and an unknown namespace attribute, alongside fixed GPS. Native
XML readback checks all these values after interrupted publication and retry.
This is richer generated XMP, not an original camera-produced sidecar.

## Environment and fixture identity

macOS 27.0.1 (26A434), arm64, Apple M5 Pro (`Mac17,8`), 64 GiB RAM,
Xcode 27.0 (27A266a).
Isolated Apple Development signed DEBUG app: `build/continuation-tests/Build/Products/Debug/Aagedal FTP Sync.app`,
3.0.0 (44). Private authorized fixture copies are staged only inside this ignored
DEBUG bundle, which is re-signed and strictly verified before testing.

ExifTool identifies the CR3 as Canon EOS R1, 6000×4000.
CR3 SHA-256: `c915aeb4a660f4030c37fb2a45e882bb20fc280c68316a6eb329ecf2988f0484`.
The ARW regression uses the previous Sony fixture, SHA-256
`4ceb7e1b59737362d0b3aa16fa04c3461f59bd4acb9e277be47eb61f054936dd`.
Original user files are read-only; private paths and image bytes are not committed.

## Verification

The focused `LocalMatchingPublicationTests` suite passes 31 tests with four
opt-in skips and zero failures (exit 0), including 32 RAW-pair format/folder/defect
combinations inside the whole-group validation regression. Development identity,
security guards and `git diff --check` pass.

The four signed native cases pass with no skips or failures (156.407 seconds,
exit 0): Sony ARW and Canon CR3, each in ordinary and managed folders.
Reprocessing is killed at `beforeCommit`. Relaunch blocks publication, Cancel
preserves the transaction, explicit test-assisted reconciliation preserves both
versions, retry preflight is read-only, retry publishes one image without failures,
and a further relaunch suppresses repeated processing using the current receipt.
RAW source/holding/restored/retried bytes and modification dates are checked.
Foundation XML readback verifies City plus the retained rich XMP fields.

The initial invocation was interrupted after a missing ARW copy was detected;
it exited 75 and supplies no pass evidence. Correcting the previous-worktree
resource path, re-signing and verifying the bundle resolved the fixture setup.
The desktop inventory showed Photo Agent idle; no competing Xcode test runner
was active. A read-only native desktop inspection took about six minutes to
return. No companion state or user settings were edited.

Logs:

- `/private/tmp/aftpsync-cr3-build.log`
- `/private/tmp/aftpsync-cr3-ui-final.log`
- `/private/tmp/aftpsync-cr3-unit.log`

Focused unit result bundle:
`build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.08_19-06-46-+0200.xcresult`.

Passing UI result bundle:
`build/continuation-tests/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.10.08_19-03-58-+0200.xcresult`.

Reproduction uses the existing smoke scheme and isolated build directory:

```sh
xcodebuild build-for-testing -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/continuation-tests -disableAutomaticPackageResolution \
  DEVELOPMENT_TEAM=YOUR_LOCAL_TEAM
# Stage only authorized copies as Contents/Resources/UITestRecovery.arw and
# UITestRecovery.cr3 in the DEBUG app, re-sign with the exact development
# identity preserving entitlements/identifier/flags/runtime, and strictly verify.
TEST_RUNNER_AAGEDAL_NATIVE_RAW_RECOVERY=1 xcodebuild test-without-building \
  -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSyncUISmokeTests \
  -destination 'platform=macOS' -derivedDataPath build/continuation-tests \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  DEVELOPMENT_TEAM=YOUR_LOCAL_TEAM \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testCameraRawPublicationReconcilesAndRetriesAcrossRelaunch \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testManagedCameraRawPublicationReconcilesAndRetriesAcrossRelaunch \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testCanonRawPublicationReconcilesAndRetriesAcrossRelaunch \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testManagedCanonRawPublicationReconcilesAndRetriesAcrossRelaunch
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/continuation-tests \
  -disableAutomaticPackageResolution DEVELOPMENT_TEAM=YOUR_LOCAL_TEAM \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests
Scripts/check-release-identity.sh
Scripts/check-security-baseline.sh
```

Without explicit opt-in, camera UI cases skip. An opted-in missing fixture
fails. Rebuild/restage after any command that changes the app bundle; never stage
private test media in a Release candidate.

## Remaining gates

Other camera families, original rich sidecars, additional interruption boundaries,
scoped Programming/conflict batches, ordinary-sync interruption, VoiceOver,
macOS 14 runtime, production performance and complete signed Release acceptance
remain open. These focused DEBUG cases do not complete M5 or establish release readiness.
