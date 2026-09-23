# 3.0 matching-clip image and calendar conflict follow-up — 2026-09-23

Base source: `4aa884e` plus the changes committed with this report. Host:
macOS 27.0 (26A428), Xcode 27.0 (27A266a). These are isolated development
tests, not a signed Release candidate or supported-OS matrix.

## Native image result

The disposable JPEG recovery fixture now has an opt-in matching clip mode:
`MAP_recovery.jpg` has a camera capture timestamp at 09:30 local time within
the seeded 09:00–10:00 clip, and that clip requests Headline `Scoped capture`.
The ordinary and managed-folder native UI tests each first confirm that a
retained transaction blocks full and clip-scoped reprocessing. After explicit
fixture reconciliation, they select **Reprocess This Clip’s Files**, inspect
the one-file preflight, publish, and relaunch. ImageIO independently reads the
published IPTC Headline `Scoped capture` and scheduled City `Oslo`. Both tests
also assert unchanged source bytes, unchanged output modification date, and
byte-identical output on repeat review. The two focused signed UI tests pass
with zero failures. The first run failed only because the test expected the
named-area City instead of the clip's scheduled GPS City; the corrected
expectation passed in the complete focused rerun.

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/v3-full-ui-sep22 \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testProgrammingPublishesMatchingClipImageAfterRecovery \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testManagedProgrammingPublishesMatchingClipImageAfterRecovery
```

The command exited 0; the concise log is
`build/v3-matching-clip-ui-test.log`. A sandboxed attempt could not write
Xcode's external caches; the permitted run compiled, and its first test pass
exposed the incorrect City assertion described above.

## Calendar conflict result

A focused coordinator regression now changes the server a second time after
local conflict review is opened. It proves the stale choice sends no calendar
write, leaves the local template edit intact, and saves the newest server
revision as an active conflict. The agent's focused Xcode test passed 1/1 in
its separate `build/v3-calendar-conflict-agent` DerivedData directory.

At the time of that result, the conflict check covered the coordinator only.
Native interrupted-image reconciliation, camera RAW and external-reader
integrity, older-client process rejection, and supported macOS/VoiceOver
evidence remain open.

## Native calendar conflict review follow-up

Commit `208d4f6` adds an isolated, committed version 3 fixture and a signed
macOS UI test for the actual conflict sheet. The fixture starts with an active
local headline edit and a competing server headline edit. Applying **This Mac**
receives a newer server revision. The sheet stays open with the stale-review
warning; **Refresh Review** shows the newest server headline, retains the local
headline, and requires a new choice. The fake transport accepts only
`getCalendar`, so this path cannot publish a stale choice.

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/v3-calendar-conflict-ui \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testVersion3CalendarConflictReviewRejectsServerChangeAndRefreshes
```

The focused signed run passed 1/1 with zero failures on macOS 27.0 / Xcode
27.0; the log is `build/v3-calendar-conflict-ui-test.log`. Earlier fixture
iterations failed before the final passing run while establishing a committed
v3 library and attaching its paused coordinator. This is development-host
evidence, not the supported-OS or VoiceOver release matrix.
