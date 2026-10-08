# M3 routine launch experience verification — 2026-09-13

Implementation commit: `f1d0ce5`. This is development evidence, not a release
candidate or a completed recovery matrix.

## User-visible behavior

Routine startup no longer presents the technical source-selection screen:

- A fresh installation creates its empty version 3 store without opening Startup and
  Recovery.
- An ordinary populated 2.9 installation shows a single **Upgrade to 3.0** action. It
  selects current primary stores only, retains the original data, and never falls back
  to a backup after validation failure. **Review Migration Details…** remains available.
- A healthy committed version 3 store opens automatically on later launches.
- A backup-only, incomplete or ambiguous source inventory still opens **Recovery
  Migration** with explicit source choices and the other-copies acknowledgement.
- Migration and prepared recovery still publish jobs paused. Only a later committed
  reopen restores jobs that were configured to start on launch; calendar sync remains
  explicit.

Every migration still validates the complete selected inventory under writer exclusion,
and the cooperative version 3 lease still gates publication. Originals and backups are
not replaced by this launch simplification.

## Automated verification

The complete application suite passed on macOS 27.0 (26A428), Apple silicon:

```sh
xcodebuild -quiet test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/v3-launch-ux CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO
```

Result: 1,128 passed, 16 intentional opt-in skips and zero failures from 1,144
discovered tests. Result bundle:
`build/v3-launch-ux/Logs/Test/Test-AagedalFTPSync-2026.09.13_22-37-37-+0200.xcresult`.

Three signed native UI tests passed together:

```sh
xcodebuild -quiet test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/v3-launch-ux-ui -parallel-testing-enabled NO \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testVersion3StartupMigratesPopulatedStorePausedAndReopensIt \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testVersion3FreshInstallSkipsStartupAndRecoveryWindow \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testVersion3BackupOnlySourceUsesDetailedRecoveryMigration
```

Result: three passed, zero failures. Result bundle:
`build/v3-launch-ux-ui/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.13_22-51-57-+0200.xcresult`.

The security dependency baseline and unchanged 2.9.2 (37) release-identity guard
passed. An unsigned arm64 Release build completed at
`build/v3-launch-ux-release/Build/Products/Release/AagedalFTPSync.app`; its executable
SHA-256 is `70df09deb24a06d31c9b5a6fd01703582f6cf86108fe232d12d6dd0a4bce1076`.

## Remaining boundary

A full signed UI-suite attempt before the final launch-test timing correction was not a
pass: 11 of 16 tests passed. The two launch assertion races were corrected and all
three launch tests then passed together; three unrelated map/variable-editor UI cases
still require a clean full-suite rerun. Damaged-primary, prepared-recovery,
simultaneous-copy, downgrade and supported-OS native matrices also remain open. No
user-lane checklist result was recorded.
