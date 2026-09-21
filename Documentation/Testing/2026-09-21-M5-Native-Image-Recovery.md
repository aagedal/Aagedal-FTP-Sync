# Native image recovery fixture — 2026-09-21

Source: `4d6486d` plus the changes committed with this report, on
`codex/version-3-0-plan`. Host: arm64 macOS 27.0 (`26A428`), Xcode 27.0
(`27A266a`). Development identity: 3.0.0 (38). The historical candidate and
private checklist lanes remain unchanged; no local results JSON was present.

## Scope

The isolated recovery fixture can now include a generated, decodable JPEG in a
nested destination folder. Its GPS falls inside a deterministic named area,
so City-only publication uses the production pipeline without network requests.
Both ordinary destinations and managed `Synced Files` are covered. The job stays
disabled and source bytes remain disposable. Normal launches do not enable this
fixture.

The hosted regression verifies blocked admission, explicit reconciliation with
retained text snapshots, read-only image preflight, City publication, preserved
source bytes and modification date, durable audit receipt, and a repeat that does
not rewrite the published image. The native regressions extend the existing
shared-editor recovery/cancellation/relaunch flow through actual publication,
read City independently with ImageIO, and check that relaunch offers no ready
files and preserves the published bytes.

This is image publication following text-fixture recovery. It does not prove
reconciliation of an interrupted JPEG transaction or camera RAW/XMP. Nor does it
close scoped Metadata Programming, conflict, VoiceOver or supported-OS gates.

## Verification

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build-for-testing -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

- Focused non-UI: 27 executed, 23 passed, four opt-in skips, zero failures, exit 0.
- Signed UI build: exit 0.
- Security, development identity and diff checks: exit 0.

Initial hosted runs rejected an overly specific current-receipt assertion. The
fixture has no historical source-signature record, so its first publication's
source evidence falls back to the destination before enrichment; the next scan
can skip because City is already filled without describing the receipt as current.
The regression now checks the actual required properties independently: persisted
fingerprint, zero repeat writes and unchanged bytes. The named-area ID was also
made stable. No production receipt behavior was changed.

The initial restricted Xcode command could not access compiler/SwiftPM caches;
approved invocations completed. Logs: `build/v3-native-image-recovery-unit.log`,
`build/v3-native-image-recovery-unit-final.log` (initial assertion failures),
`build/v3-native-image-recovery-unit-pass.log`, and
`build/v3-native-image-recovery-ui-build.log`.

Passing hosted result:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.21_12-18-17-+0200.xcresult`.

Native run (serialized after Photo Agent reported its UI tests complete):

```sh
xcodebuild test-without-building -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testImageRecoveryPublishesAndRetainsResultAcrossRelaunch \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testManagedImageRecoveryPublishesAndRetainsResultAcrossRelaunch \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testRetainedMetadataRecoveryExplainsBlockedReprocessingAndAllowsRetry \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testManagedMetadataRecoveryExplainsBlockedReprocessingAndAllowsRetry
```

App: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.
App-code debug dylib SHA-256:
`e7896e4e771657d33f477a031c2aa36c252e90158f0d5617d2c1616cfaa091e8`.
Native log: `build/v3-native-image-recovery-ui.log`.

Native result: all four signed tests passed, zero failures, exit 0 (150.093 s).
The ordinary/managed image cases took 37.337/37.762 s. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.21_12-19-30-+0200.xcresult`.
Computer-use inventory succeeded before testing; a separate post-test attachment
to the exact built app timed out. It supplies no additional visual evidence.
Native observations above come from XCTest accessibility assertions and ImageIO
readback. No full-suite or release-candidate pass is claimed.
