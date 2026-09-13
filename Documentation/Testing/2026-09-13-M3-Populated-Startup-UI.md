# M3 populated startup UI verification — 2026-09-13

Implementation commit: `2e76ad4`. This is native development evidence, not a
release-candidate or a complete migration/recovery acceptance pass.

## Isolated fixture and workflow

The UI-test harness can now seed a populated legacy `jobs-v2.json` only when both
`AAGEDAL_UI_TESTING=1` and `AAGEDAL_UI_TEST_V3_STARTUP=1` select a unique temporary
session root. Production Application Support, Keychain values, calendars and network
transports are never selected. The fixture is an enabled local job configured to start
on launch, with placeholder bookmarks inside that isolated root.

The signed application completed this native workflow on macOS 27.0 (26A428), Apple
silicon:

1. Startup and Recovery opened automatically for the explicit version-3 test mode.
2. The populated legacy source was detected and **Prepare 3.0 Copy** remained gated by
   the other-copies acknowledgement.
3. Migration reached **Review before starting** and stated that jobs and calendar sync
   remained paused.
4. The menu-bar UI showed **Migrated 2.9 UI Fixture** with **Start**, proving that the
   migrated job was published but not activated during migration.
5. After terminating and relaunching against the same isolated root, the UI offered
   **Open Saved 3.0 Data** rather than another migration.
6. The committed store opened, reported that launch-configured jobs were active, and
   the same job appeared with **Stop**. Calendar sync remained paused.

Command:

```sh
xcodebuild -quiet test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/v3-populated-ui -parallel-testing-enabled NO \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testVersion3StartupMigratesPopulatedStorePausedAndReopensIt
```

Result: one test passed, zero failures. Result bundle:
`build/v3-populated-ui/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.13_20-45-53-+0200.xcresult`.
The exercised Debug executable SHA-256 was
`225341bcb7bbdbd00f354f43de8a0d6d1a651b7fd0543dde3f6567c995fd77c5`.

## Supporting verification

The focused startup-path, bootstrap-coordinator and startup-controller selection ran
26 tests with zero failures in a non-sandboxed test host (`CODE_SIGNING_ALLOWED=NO`).
The application security dependency baseline and the intentionally unchanged 2.9.2
(37) release-identity guard also passed.

## Remaining boundary

This adds native populated migration and committed relaunch evidence to M3. It does not
cover damaged-primary/backup selection, prepared recovery, simultaneous-copy conflict,
downgrade restoration, classic-calendar migration, supported macOS 14, or the full
candidate UI matrix. The formal 3.0 checklist remains separate and no user-lane result
was recorded.
