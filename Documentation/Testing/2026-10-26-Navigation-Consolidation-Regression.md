# Navigation consolidation regression run — 2026-10-26

## Scope

First complete test run after the navigation consolidation merge (`4cc8720`),
on `t3/82b5ecea`. Host: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a),
development identity 3.0.0 (44). Source changes in this run: one stale
"Settings → Sync Servers" instruction now names the renamed **Shared Calendars**
tab, and one UI smoke test closes Settings before returning to the job sheet.

## Results

- Security dependency baseline and development-identity guards pass.
- Complete unsigned hosted suite: **1,355 tests, 30 opt-in skips, zero failures**,
  exit 0 (`build/logs/unit.log`).
- Complete signed UI smoke suite (90 tests): 34 passed, 42 opt-in skips (authorized
  camera RAW not staged), 14 failed, exit 65 (`build/logs/ui.log`).

### Failure 1 — test defect, fixed

`testOpenJobConnectionRefreshesWhenSharedServerChangesInSettings`: the app correctly
refreshed the open job sheet's port to the saved 2121. The Settings window then
covered the sheet's **Done** button; XCUITest reported it as an interrupting element
and clicked through to Settings, so the sheet stayed open and Save never ran. The test
now closes Settings first and passes alone (exit 0, 29.2 s).

### Failures 2–14 — host permission, not a product defect

Thirteen native recovery tests (ordinary/managed publication, processed handoff,
image recovery, metadata recovery, Programming recovery) fail when the test runner
reads fixtures inside `~/Library/Containers/no.aagedal.AagedalFTPSync/Data/tmp`:
`NSCocoaErrorDomain 257 / POSIX 1 Operation not permitted`. The same tests passed on
this host on 2026-10-18 (see `2026-10-18-M5-Native-Processed-Handoff-Recovery.md`),
and the recovery code is unchanged since then. A single-test rerun reproduces the
failure deterministically. This matches macOS app-container data protection denying
the runner built from this new worktree. Granting **AagedalFTPSyncUITests-Runner**
access to other apps' data (Privacy & Security), then rerunning the suite, is
required. These tests are **not** counted as passing.

## Not covered

Native layout at accessibility text sizes, VoiceOver order and supported-OS runs
remain pending for the navigation changes.
