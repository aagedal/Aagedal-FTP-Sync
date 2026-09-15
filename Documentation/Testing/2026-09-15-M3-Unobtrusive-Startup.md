# 2026-09-15 unobtrusive version 3 startup

At source base `98869ab7dabf5456d6849ce69778f44c328033cc` plus the owned
startup/menu/settings/test changes, a routine first launch now migrates an
unambiguous current 2.9 inventory automatically. The migration still copies into
separate version 3 storage, retains the legacy files, rechecks source inventory
and content under the writer exclusion/lease, and pauses jobs and calendar sync.
Backup-only or ambiguous inventories require source review; malformed primary
data fails closed without backup fallback. Another running copy blocks admission.
Healthy committed version 3 data still opens automatically on relaunch.

The ready menu-bar panel no longer appends a permanent “Startup and Recovery…”
button. Recovery attention remains available when admission is blocked, and the
calendar activation action is now in Settings → Metadata Sync → Calendar Sync.
The ordinary paused-calendar banner was removed from every store-backed window.

Verification on arm64 macOS 27.0 with Xcode 27.0:

- The app-hosted `Version3StartupControllerTests` selection passed 14/14 in the
  isolated `build/v3-startup-ux` DerivedData directory. The populated-primary
  case asserts the current job wins over a different retained backup and the
  first migrated session remains paused. Concurrent-copy/publication and
  recovery tests remained in the selection.
- Isolated macOS UI smoke cases passed 7/7 across three Xcode invocations,
  with the calendar-settings case repeated successfully after its final copy and
  message-state edit:
  populated migration/relaunch, fresh install, damaged primary, programmed
  filename-filter editing, backup-only review, prepared-copy recovery, and the
  calendar activation control in Settings. The fresh/populated tests observe no
  startup window and no ready-panel `startup.open` element. The isolated settings
  control is visible but disabled, as test sessions cannot activate calendar network.
- `Scripts/check-security-baseline.sh`, `Scripts/check-release-identity.sh` and
  `git diff --check` passed. The UI-test app's bundled AuraFace resource passed
  `Tools/verify_bundled_auraface.py app`.

The Xcode commands used `xcodebuild test -project 'Aagedal FTP Sync.xcodeproj'
-destination 'platform=macOS' -derivedDataPath build/v3-startup-ux
-clonedSourcePackagesDirPath build/SourcePackages -parallel-testing-enabled NO`
with scheme `AagedalFTPSync` for the app-hosted class selection and
`AagedalFTPSyncUISmokeTests` for the named UI cases. Each command exited 0;
their full output is retained in ignored local files
`build/v3-startup-ux-test.log`, `build/v3-startup-ux-ui-test.log`,
`build/v3-startup-ux-ui-followup.log` and
`build/v3-startup-ux-ui-calendar-final.log`.

The checkout also held unrelated uncommitted Xcode project/scheme target-renaming
and string-catalog edits. They were not changed or staged for this slice. That
target rename makes the checked-in app-hosted test path and UI `TEST_TARGET_NAME`
stale, so the test commands used temporary command-line overrides:

- App-hosted: `TEST_HOST=$(BUILT_PRODUCTS_DIR)/Aagedal FTP Sync.app/Contents/MacOS/Aagedal FTP Sync`
- UI: `TEST_TARGET_NAME=Aagedal FTP Sync`

The test app launches under UI automation and carries a team code signature, but
`codesign --verify --deep --strict` reports `CSSMERR_TP_NOT_TRUSTED` on this host.
This is not a trusted signed Release candidate. The development candidate file
still points to the older `9f04fad` build; supported-macOS and release-candidate
verification remain open.
