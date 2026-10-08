# Native camera RAW interruption and recovery — 2026-10-08

## Scope and source

Continuation branch: `t3code/continue-3-0-implementation-1`, based on merged
`1a644a4`. Source changes are limited to `UITestSupport.swift`, the focused
publication tests and the native smoke tests. Tested implementation commit: `9702f78`, with documentation edits pending
when checks ran; no unrelated source changes were present. No shipping processing or recovery behavior changed.

Host: macOS 27.0.1 (26A434), arm64, Xcode 27.0. Development app:
`build/continuation-tests/Build/Products/Debug/Aagedal FTP Sync.app`, 3.0.0 (44),
Apple Development signed. This is an isolated DEBUG test build, not the tracked
Developer ID Release candidate. No candidate or manual-checklist results changed.

The operator-authorized Sony ARW is copied read-only into the ignored test app
bundle as `Contents/Resources/UITestRecovery.arw`, then the app is re-signed and
strictly verified. The app copies it into its disposable session. A generated
valid XMP supplies fixed GPS and a Unicode description. A local polygon resolves
City to `Recovery Venue`, with no network or recognition inference. ExifTool identifies the staged asset as SONY ILCE-1 ARW, 8704×6144.
Fixture SHA-256: `4ceb7e1b59737362d0b3aa16fa04c3461f59bd4acb9e277be47eb61f054936dd`.
Private image paths and bytes are not committed; the operator's original is untouched.

## Observed native behavior

Both ordinary and managed `Synced Files` destinations pass the native case.
Reprocessing is interrupted with SIGKILL at `beforeCommit`. The actual transaction
contains two originals: the guard-only RAW and the replaced XMP. The new XMP is
visible while the RAW remains in its holding. Relaunch blocks reprocessing and
reports the retained transaction; Cancel preserves it.

Explicit test-assisted reconciliation validates the complete strict path map,
regular nonredirected files, source/held/snapshot byte agreement and the published
XMP snapshot before changing either member. A pre-existing RAW destination, changed
source/publication, competing transaction or existing rescue prevents mutation.
The helper preserves the published XMP and complete original transaction outside
the destination, then restores the chosen original pair with filesystem dates.
This is DEBUG fixture plumbing, not automatic production reconciliation.

Native retry preflight checks one image without changing XMP bytes. Publication
reports one applied file, no skips and no failures. Independent Foundation XML
readback confirms City and the unchanged Unicode description. The test compares
RAW source, holding, restored and retried output bytes, plus modification dates.
A further relaunch has a current receipt, disables another publication, and retains
the successful pair and both recovery choices.

The focused regression adds 12 synthetic RAW-pair combinations across both folder
modes, including changed RAW/XMP sources, edited XMP output, a new RAW destination,
a redirected RAW holding, success and repeated reconciliation. All evidence is
checked before mutation, including when only the second member is invalid.

## Verification

- Focused `LocalMatchingPublicationTests`: 31 executed, four opt-in skips,
  zero failures; exit 0.
- Signed native ARW/XMP recovery: two executed, no skips/failures; exit 0;
  84.312 seconds for both cases.
- Existing signed native JPEG recovery: two executed, no skips/failures; exit 0;
  74.982 seconds.
- Development identity/security guards and whitespace check pass.

Logs are `/private/tmp/aftpsync-native-raw-build.log`,
`/private/tmp/aftpsync-native-raw-unit.log`,
`/private/tmp/aftpsync-native-raw-ui-final.log` and
`/private/tmp/aftpsync-native-raw-jpeg-regression.log`.
Result bundles are under `build/continuation-tests/Logs/Test/`:

- `Test-AagedalFTPSync-2026.10.08_18-03-08-+0200.xcresult`
- `Test-AagedalFTPSyncUISmokeTests-2026.10.08_18-04-27-+0200.xcresult`
- `Test-AagedalFTPSyncUISmokeTests-2026.10.08_18-06-25-+0200.xcresult`

The initial bundle signing attempt used a duplicated certificate display name and
failed. Its attempted native run exited 75 and is not pass evidence. Selecting an
exact valid identity fingerprint and verifying before testing resolved it.
Read-only shell access to the sandboxed app's retained fixtures is denied by the
host privacy boundary; no new ExifTool output-pair verification is claimed here.
The native runner's byte/date checks and XML readback are the evidence for this
case. The earlier camera-media ExifTool matrix remains separate evidence.
Photo Agent was running unit tests, rather than native desktop automation, when
these native cases started. Separate dependency caches and build directories were used.

## Reproduction

Build for testing with the `AagedalFTPSyncUISmokeTests` scheme, then copy only an
authorized ARW into the resulting DEBUG app resource path above. Re-sign that app
with the exact local Apple Development fingerprint, preserving its entitlements,
identifier, flags and runtime, and verify `codesign --verify --deep --strict`.
Use `test-without-building` so Xcode does not replace the staged signed bundle.
Never stage private test assets in a release candidate.

```sh
xcodebuild build-for-testing -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/continuation-tests -disableAutomaticPackageResolution \
  DEVELOPMENT_TEAM=YOUR_LOCAL_TEAM
# Copy the authorized ARW and re-sign/verify the DEBUG app before this step.
TEST_RUNNER_AAGEDAL_NATIVE_RAW_RECOVERY=1 xcodebuild test-without-building \
  -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSyncUISmokeTests \
  -destination 'platform=macOS' -derivedDataPath build/continuation-tests \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  DEVELOPMENT_TEAM=YOUR_LOCAL_TEAM \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testCameraRawPublicationReconcilesAndRetriesAcrossRelaunch \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testManagedCameraRawPublicationReconcilesAndRetriesAcrossRelaunch
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/continuation-tests \
  -disableAutomaticPackageResolution DEVELOPMENT_TEAM=YOUR_LOCAL_TEAM \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests
Scripts/check-release-identity.sh
Scripts/check-security-baseline.sh
```

Rebuild/restage the UI bundle after any build that changes it. Without explicit
opt-in, the two camera cases skip. A missing staged asset after opt-in is a failure.

Remaining: other camera families and rich camera sidecars, other interruption
boundaries, scoped Programming/conflict batches, native ordinary-sync interruption,
VoiceOver, macOS 14, signed Release observation, production performance and final
candidate acceptance. No complete M5 or release gate is closed by these cases.
