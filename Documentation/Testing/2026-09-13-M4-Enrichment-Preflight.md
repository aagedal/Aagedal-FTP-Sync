# M4 enrichment preflight and full-suite recovery

Date: 2026-09-13

Source: `c23eb6d360e695f2a9c26f3352c30bca3492efa8`

Environment: Apple silicon, macOS 27.0 (26A428), Xcode 27.0 (27A266a)

Candidate status: development only; not ready for user acceptance

## Finding and fix

The first current-source full-suite run exposed two deterministic failures. Face
integration had made `MetadataProcessingCoordinator.prepare` read existing Person
Shown metadata before validating geocoding settings and even for disabled literal
processing. Consequences included opening a staged image before rejecting missing
Apple-coordinate consent and losing the established no-read fast path.

The coordinator now validates provider/privacy and face-runtime prerequisites before
opening the file. It reads existing person names only when recognition is requested or
an activated template references `{persons}`. A new regression proves that existing
Person Shown values still resolve `{persons}` without running recognition.

## Verification

The four affected integration classes passed 44 tests with zero failures or skips:

```text
xcodebuild test -quiet -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-launch-restoration-full \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:AagedalFTPSyncTests/MetadataGeocodingProviderRoutingTests \
  -only-testing:AagedalFTPSyncTests/MetadataOfflineProcessingCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/MetadataProcessingCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests
```

The complete app unit/integration suite then finished normally at the same source:
1,141 tests discovered, 1,125 passed, 16 opt-in tests skipped and zero failed.

```text
xcodebuild test -quiet -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-launch-restoration-full \
  CODE_SIGNING_ALLOWED=NO
```

`Scripts/check-security-baseline.sh` passed. An unsigned Release build completed at
`build/DerivedData-launch-restoration-release/Build/Products/Release/AagedalFTPSync.app`.
The executable SHA-256 is
`bb0a705a47304c46ea33ff583060d5e370096825a262aab45a54f8fe1015181b`.
The initial sandboxed rebuild could not access Xcode's normal caches; the identical
command succeeded with normal Xcode cache access. Build warnings remained in vendored
Citadel/swift-nio-ssh sources.

## Remaining boundary

The 16 skips are opt-in external/fixture checks and do not count as candidate evidence.
No signed UI, native workflow, supported-OS, live-provider or real-face acceptance is
claimed by this run.

