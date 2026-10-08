# M3 admitted launch restoration

Date: 2026-09-13

Source: `ba9a0b50bd99cb7021fe73e87bce5f1d64660f02`

Environment: Apple silicon, macOS 27.0 (26A428), Xcode 27.0 (27A266a)

Candidate status: development only; not ready for user acceptance

## Implemented

- First migration and prepared-copy recovery continue to publish a fully paused
  runtime for deliberate review.
- Opening an already committed and validated version 3 store now restores only jobs
  whose saved **Enable automatically on app launch** choice is on. Restoration occurs
  after writer-exclusion and storage-lease revalidation and does not rewrite the
  saved job store merely because the app launched.
- Jobs requiring unavailable face-recognition dependencies remain stopped and expose
  the existing actionable blocker. Calendar sync remains a separate explicit action.
- The persistent startup banner now describes the calendar pause without incorrectly
  implying that every admitted session has just migrated.

## Verification

The affected selection passed 38 tests with zero failures or skips:

```text
xcodebuild test -quiet -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-launch-restoration \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:AagedalFTPSyncTests/Version3StartupControllerTests \
  -only-testing:AagedalFTPSyncTests/Version3BootstrapCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/SyncSchedulerTests \
  -only-testing:AagedalFTPSyncTests/MetadataFaceRecognitionSettingsTests
```

New regression coverage proves that migration remains paused, a later committed open
restores only the configured job, runtime restoration does not modify the saved v3
payload, calendar sync stays paused, and unavailable face jobs cannot start.

`Scripts/check-security-baseline.sh` passed. An unsigned Release build completed at
`build/DerivedData-launch-restoration-release/Build/Products/Release/AagedalFTPSync.app`.
The executable SHA-256 is
`6e931980321d0e27d424dd6797e9721bdf075fb3c236503a9b752f1d219b55c7`.
Build warnings were confined to vendored Citadel/swift-nio-ssh sources.

## Remaining boundary

No native UI or signed/supported-OS run is claimed. Calendar startup policy remains
deliberately explicit, and the app still depends on user-mediated exclusion of older,
noncooperating copies. Active conflict cancellation is not a proven drain barrier.

