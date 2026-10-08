# M4 explicit AuraFace model installer controls

Date: 2026-09-13

App-code source: `419d03149d2ee8042c3e346baafe237021087c01`

Environment: Apple silicon MacBook Pro, macOS 27.0 (26A428), Xcode 27.0

Candidate status: development only; not ready for user acceptance

## Implemented

- The version 3 bootstrap now constructs one model-component controller from the
  same codesigned trust configuration and admitted storage root used by startup.
  Construction and settings opening perform only local status inspection; network
  access remains behind the explicit **Download and Install Model** action.
- People Library settings show the model's checking, absent, downloading,
  installing, installed, offline, verification-failed and cancelled states. The
  user can retry, cancel and explicitly confirm removal.
- The UI explains that an installed component is admitted only on relaunch and
  that an already admitted immutable runtime remains alive until the current app
  quits. Missing or malformed production configuration shows a visible disabled
  status without blocking transfer or library management.
- Terminal controller transitions now release completed task ownership and
  invalidate queued progress callbacks, preventing a late download callback from
  replacing an installed/error/cancelled state.
- English catalog entries and stable accessibility identifiers cover the added
  model controls. The isolated UI-test store exposes People Library settings, and
  a signed-smoke case checks the unconfigured-build status.

No production public key, fixed host, signed hosted artifact, or calibrated
policy was added. Recognition therefore remains deliberately disabled in the
development build.

## Verification

Focused unit/integration selection:

```text
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-face-installer-ui-verify \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:AagedalFTPSyncTests/AuraFaceComponentInstallerTests \
  -only-testing:AagedalFTPSyncTests/Version3BootstrapCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/Version3StartupControllerTests \
  -only-testing:AagedalFTPSyncTests/PeopleLibraryControllerTests \
  -only-testing:AagedalFTPSyncTests/MetadataFaceRecognitionSettingsTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataPreviewTests
```

Result: 55 passed, zero failed, zero skipped. The new controller regression proves
that refresh is network-free, install reaches the three pinned URLs, removal is
offline, offline failures are distinct, and cancellation cannot be overwritten by
a late completion.

Complete suite:

```text
xcodebuild test -quiet -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-face-installer-ui \
  CODE_SIGNING_ALLOWED=NO
```

Result bundle:
`build/DerivedData-face-installer-ui/Logs/Test/Test-AagedalFTPSync-2026.09.13_16-35-53-+0200.xcresult`

Result: 1,126 passed, 16 opt-in skips, zero failures (1,142 discovered).

Additional checks:

- `Scripts/check-security-baseline.sh`: passed.
- `xcstringstool compile` for the English catalog: passed.
- Unsigned arm64 Release build: passed at
  `build/DerivedData-face-installer-ui-release/Build/Products/Release/AagedalFTPSync.app`.
- UI smoke `build-for-testing` with code signing disabled: passed, including the
  new People Library/model-status case.
- Release executable SHA-256:
  `ba41fc96364760395e66019e485006aeb9bfe2197989e99e7f37bdf40a6011fd`.

Existing warnings are confined to vendored Citadel/swift-nio-ssh sources. No
changed app file emitted a warning.

## Remaining boundary

No signed UI test or native settings interaction is claimed. The desktop runner's
earlier authentication cancellation remains unresolved. Production distribution
identity/hosting, real installer download and signature validation, supported-OS
execution, real-face calibration, actual-face evidence and measured resource-cap
tuning remain release gates.
