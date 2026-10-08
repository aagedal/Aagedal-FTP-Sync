# M2 public offline edges and current non-UI verification — 2026-09-14

Fixture commit: `9057456`. This is development evidence, not a beta or release
candidate. No SwiftUI or UI test was started in this cycle.

## Public offline geography fixtures

The pinned GeoNames adapter now has deterministic public-coordinate coverage for
the remaining rural, coastal and nearby cross-border shapes:

- Hardangervidda (`60.1000, 7.5000`) returns `tooDistant`; the app does not invent
  a settlement beyond its fixed 50 km policy.
- Sola coast (`58.8887, 5.6009`) returns a Norwegian settlement within the policy.
- Helsingør (`56.0361, 12.6136`) and Helsingborg (`56.0465, 12.6945`) resolve to
  distinct Danish and Swedish settlements within 5 km of each query. Exact query
  coordinates remain separate; no coarse spatial cache rounding is introduced.
- Existing coverage retains Point Nemo as an excessive-distance outcome, Oslo and
  localized Tokyo results, strict-distance rejection and pinned provider/dataset
  provenance.

The manual case `m2-004` now names the exact public fixture coordinates and expected
policy shape. Actual image import, preview, transfer, reprocessing, supported-OS and
external-reader observations remain separate gates.

Final focused command:

```sh
xcodebuild -quiet test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/v3-full-nonui-current CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO \
  -only-testing:AagedalFTPSyncTests/OfflineMetadataGeocodingProviderTests
```

Result: 5 passed, zero skipped or failed. Result bundle:
`build/v3-full-nonui-current/Logs/Test/Test-AagedalFTPSync-2026.09.14_15-10-57-+0200.xcresult`.

## Complete application test target

The complete non-UI application target at `9057456` passed 1,130 tests with 16
opt-in skips and zero failures (1,146 total):

```sh
xcodebuild -quiet test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/v3-full-nonui-current CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO -only-testing:AagedalFTPSyncTests
```

Result bundle:
`build/v3-full-nonui-current/Logs/Test/Test-AagedalFTPSync-2026.09.14_15-19-14-+0200.xcresult`.

An initial run without `CODE_SIGNING_ALLOWED=NO` produced 161 failures because the
signed App Sandbox test host could not create the suite's disposable `/private/tmp`
fixtures. The result bundle records Cocoa error 513 / POSIX `EPERM`; it is not counted
as product evidence. Repeating the documented unsandboxed non-UI configuration passed.

## Other guards and build

- Security dependency baseline: passed.
- Current development identity guard: passed for unchanged 2.9.2 (37).
- Checklist catalog JSON parsing and all five localhost persistence/isolation tests:
  passed. The first sandboxed checklist attempt could not bind localhost and is not
  counted; the allowed rerun passed.
- Unsigned arm64 Release build at `9057456`: passed. App:
  `build/v3-geocoding-edge-release/Build/Products/Release/AagedalFTPSync.app`.
  Executable SHA-256:
  `d1318cc496caeefe0d3c07b3c25fb724fcb3bf38196b594937b77f3328aafd8e`.

The host is Apple silicon macOS 27.0 build `26A428`. This does not satisfy macOS 14,
signed archive, UI, live Apple provider, production face distribution/calibration,
PHP/MySQL, remote transport or final manual acceptance gates.
