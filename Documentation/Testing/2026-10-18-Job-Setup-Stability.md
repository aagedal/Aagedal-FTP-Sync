# Job setup and menu-bar state consistency — 2026-10-18

On `t3/stabilize-v3-ui`, from merged `87b3ca7`.

## Problems and changes

An open job-settings draft retained old automatic-sync, interval and filter
values after menu-bar changes. Saving an unrelated edit could therefore restart
a job the operator had stopped. Settings now refresh shared controls from the
saved job, preserving independently edited draft fields. Save also performs the
same merge before persistence. Recent-file changes retain their adjusted cleanup
safety boundary. Legacy optional launch settings stay optional, avoiding false
unsaved-change prompts. Discard returns to the latest shared-control values.

A Keychain failure previously permanently blocked saving in that editing session.
Both passwords now load before either is published; retry remains available in
the alert and in Server & Sync. Successful retry preserves typed password
replacements and other job edits. Saving remains blocked until loading succeeds.

Source and destination cards now have visible Set Up Location / Edit Location
actions. The existing connection sheet and connection tests remain available.
Intervals such as 90 seconds display as `1m 30s` rather than `1 min`. A Saved
confirmation is hidden when new edits are unsaved. README includes the first-job
workflow and the distinction between a single run and automatic syncing.

## Verification

Host: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), development identity
3.0.0 (44). No installed production app or private job configuration was changed.

- Initial focused hosted selection: 24 tests, zero failures.
- Complete unsigned hosted suite after the legacy-setting fix: 1,312 tests,
  30 expected opt-in skips, zero failures. Final follow-up adds cleanup-boundary
  assertions to an existing test; that focused test passes separately.
- Four new hosted regressions cover save after Stop/quick controls, draft rebasing
  and discard, the legacy nil launch setting, and partial Keychain failure/retry.
- Six signed native smoke tests pass together, zero failures or skips:
  `testLocationSetupHasDirectActionsAndReturnsToUnsavedDraft`,
  `testMenuBarStopUpdatesOpenSettingsAndSaveKeepsJobPaused`,
  `testCreatesJobFromDraft`, `testEditsSavedJob`,
  `testRecoversAfterVisibleSaveFailure`, and
  `testAccessibilityTextSizeKeepsCoreControlsOperable`.
- Captured job setup and local source-sheet screenshots were visually inspected.
  Direct location actions, folder chooser and Done are visible and operable.
- Security/development-identity guards, bundled-model verification, strict DEBUG
  signature verification and diff whitespace checks pass.
- Final unsigned arm64 Release build and its bundled-model verification pass.
  This is a build check, not a signed or registered release candidate.

The first native selection passed five cases; the new Stop case used a checkbox
locator for a SwiftUI switch and failed before checking Stop/save behavior. A
stable accessibility identifier fixed that test locator. The complete six-case
selection then passed. The only final production-source difference after the
complete hosted run is this accessibility identifier.

Logs and results are ignored under `build/`: `setup-full-final-tests.log`,
`setup-cleanup-test.log`, `setup-native-final-tests.log`, and
`setup-native-final-tests.xcresult`, and `setup-release-build.log`. Hosted tests use the documented unsigned
configuration and `build/continuation-tests` derived data. Native tests use
`AagedalFTPSyncUISmokeTests`, development signing and
`-parallel-testing-enabled NO`, with the six selectors above.

## Limits

This is focused setup/state verification, not final Release acceptance, native
Keychain-failure injection, VoiceOver, or macOS 14 runtime verification. Explicit
local edits to shared controls are retained; this is not general multi-window
conflict resolution for every job field. Interrupted publication, original
camera sidecars, controlled performance, companion interchange and the remaining
release gates in the readiness report still require their own evidence. The
historical candidate stays IMPLEMENTING; M5 remains open. No private checklist
results or candidate records were changed.
