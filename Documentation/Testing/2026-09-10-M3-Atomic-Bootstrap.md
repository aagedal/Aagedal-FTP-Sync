# Atomic paused bootstrap checkpoint

App-code `33e4b0a`, including separately committed calendar fix `ae2c3eb`.
Independent implementation/review completed; coordinator alone built and committed.

Version3BootstrapCoordinator has explicit migrate-selected/open-committed/recover-prepared
operations and idle/loading/ready/recovery states. Admission completes before strict AppStore
and calendar construction. Both publish as one MainActor Runtime, remaining paused. Runtime
retains the lease if the coordinator is disposed; callers must retain that owner while using
its stores. Partial construction failures keep objects private and retain the lease. One
attempt per coordinator avoids pretending that stop() drains every writer before retry.
Admission runs in an awaited detached task; cancellation is forwarded but the lease remains
held until the worker returns. The injected validator asserts independently maintained,
continuous writer exclusion; it is not a point-in-time process check or a substitute for it.

Version3StartupPaths converts trusted bootstrap parent aliases to physical POSIX paths,
checks directory identities, rejects final symlinks and creates only the final root and a
fresh 0700 temporary child. Existing roots/permissions remain untouched. Trusted parents
must already exist; never use this API for paths obtained from imported documents. Temporary
cleanup belongs to the caller after all handles close; an exceptional failure after directory
creation can leave private residue. Four tests include the actual Foundation temp location,
/tmp ancestor alias, missing/file/symlink refusal and migration under a retained lease.

## Validation and fixes

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Final exit 0, completed 2026-09-10 15:22:23 Europe/Oslo: **713 discovered,
698 passed, 15 opt-in skips, zero failures**, 34.518 seconds. All 13 new tests pass:
eight bootstrap groups, four path groups and one deterministic calendar debounce regression.
No source changed after this run. `git diff --check` passed.

The first compile exposed a Swift 6 isolation error in a Task returning the nested Runtime.
Explicit @MainActor on this UI owner fixed it, without unchecked Sendable; independently
reviewed. The next full suite passed all new bootstrap/path tests but exposed an existing
calendar coalescing assertion: an extra getCalendar after local edits were already committed.
The debounce task retained stale job IDs before its delay. Commit `ae2c3eb` now preserves
immediate Pending feedback but recalculates eligibility after the delay and checks cancellation
before dispatch. A gated regression holds the delay while manual refresh commits the baseline,
then verifies releasing the debounce does not create an echo. The full suite passed afterward;
this failure was fixed, not waived as timing noise. Installed 2.9.2 remains unchanged.

- Full log: `build/m3-atomic-bootstrap/full-tests.log`
- SHA-256: `398b02dab88d6a11ae9cd5457323f54d090304ce3640c8ed636140d8c3a721a3`
- Earlier logs: `initial-actor-compile-failure.log` and `calendar-debounce-failure.log` in the same directory.
- Result: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.10_15-21-43-+0200.xcresult`
- Built app: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Build/Products/Debug/AagedalFTPSync.app`
- Host: arm64 macOS 27.0 (26A428), Xcode 26.6 (17F113), development app 2.9.2 (37).

## Remaining product integration

Production App.main still constructs legacy stores. Replace all scenes/menu/Settings with
one gated bootstrap shell, including a menu-bar attention state and explicitly opened recovery
window for this LSUIElement app. Establish trusted system parent directories on a new sandbox,
source/backup selection UI, explicit frozen recovery and continuous older-writer exclusion.
Same-bundle running-app detection is useful evidence but not race-free prevention of 2.9
relaunches. Do not force-terminate transfers or call stopAll a drain barrier. Preserve initial
pause and later per-job launch policy separately.

Read-only activation audit is recorded in `3.0-Activation-Integration-Checklist.md`. Persisted
markers must not be accepted while either transfer/reprocessing still uses literal-only values,
or while legacy packages/calendar copies can strip activation. That audit changes no behavior.

No actual GUI observation was attempted for these opt-in paths; the prior native selection
stall remains unresolved and other app coordinators were active. No candidate, human result,
required GUI/supported-OS/remote gate or milestone checkbox was advanced. Public release remains
outside this automation and final human acceptance is still outstanding.
