# M4 startup and preview admission

Date: 2026-09-13

Source: `6d40f20354fe704a5ea857b6547e0f6b1a7ab98d`

Environment: Apple silicon, macOS 27.0 (26A428), Xcode 27.0 (27A266a)

Candidate status: development only; not ready for user acceptance

## Implemented

- Version 3 bootstrap now performs local AuraFace admission before constructing or
  publishing either app writer. The admitted analysis runtime, immutable people
  snapshot and acceptance policy are bound into one app-lifetime context shared by
  sync, explicit reprocessing and metadata preview.
- Production admission is disabled unless the codesigned bundle explicitly provides
  fixed descriptor/signature URLs, allowed HTTPS origins, a 32-byte Ed25519 public
  key and all calibrated policy values. Missing, invalid or unavailable optional
  dependencies yield no context; face-enabled jobs remain paused and fail closed.
- Startup never downloads the optional model. Component download remains an explicit
  settings operation, separated from this local admission boundary.
- Metadata preview now evaluates supported photos with the same admitted resolver as
  transfer and reprocessing, including face-only jobs. Preview stays read-only and
  refuses a requested face stage before opening the selected folder when no admitted
  context exists.
- Job saving, enabling, launch handling, Start All and the editor status now use the
  admitted runtime state. The generic no-context APIs retain their fail-closed default.
- The bootstrap revalidates cancellation, the storage lease and writer exclusion after
  optional admission and before app-store construction, preserving the all-or-nothing
  publication boundary.

## Verification

The focused regression selection passed all 127 declared tests across:

- activated metadata preview and transfer integration;
- face settings, bounded analysis and signed component installation;
- metadata-programming coordination, including replacement-preview cancellation;
- version 3 bootstrap ordering, failure containment and startup-controller behavior.

New cases prove face-only preview proposes recognized names without changing image
bytes or creating files, unavailable preview fails before folder access, an admitted
context reaches the preview operation and published AppStore, admission failure keeps
both app writers private, and production configuration is explicit and strict.

The verification command was:

```text
xcodebuild test -quiet -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-face-preview \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataPreviewTests \
  -only-testing:AagedalFTPSyncTests/MetadataFaceRecognitionSettingsTests \
  -only-testing:AagedalFTPSyncTests/MetadataProgrammingCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/Version3BootstrapCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/Version3StartupControllerTests \
  -only-testing:AagedalFTPSyncTests/AuraFaceComponentInstallerTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/FaceRecognitionAnalysisServiceTests
```

`Scripts/check-security-baseline.sh` passed. An unsigned Release build completed at
`build/DerivedData-face-preview-release/Build/Products/Release/AagedalFTPSync.app`.
Build warnings came from vendored Citadel/swift-nio-ssh sources; no changed app file
emitted a warning.

## Remaining boundary

The Release build deliberately has no AuraFace trust or policy values, so recognition
remains disabled by default. A dedicated production key and fixed hosts, signed hosted
artifacts, calibrated policy, explicit installer UI integration, authorized labeled
real-face fixtures, measured resource-cap tuning and native/supported-OS workflows
remain required. This slice does not claim GUI, signing, notarization, live service or
full-suite acceptance evidence. The application version remains 2.9.2 (37).
