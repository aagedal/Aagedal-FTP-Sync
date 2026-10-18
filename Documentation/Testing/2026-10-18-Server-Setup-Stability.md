# Reusable server and connection setup stability — 2026-10-18

Work on `t3/stabilize-v3-ui`, based on `c75a8d3`. Host: arm64 macOS 27.0.1
(26A434), Xcode 27.0 (27A266a), development app 3.0.0 (44).

## Changes

Reusable FTP/FTPS/SFTP server drafts previously disappeared when selecting another
server, adding a server, or returning from another Settings tab. Revert also did
nothing for a new draft. A dedicated editing session now retains the draft and
password baseline. Selection, Add and window close offer Save, Discard and Cancel;
new drafts have a working Discard Draft action. Incomplete connections explain
why Save is disabled. Password-loading failures have a retry action that preserves
typed replacements and other edits.

The Settings window owns the server session and close guard outside its TabView.
Closing while another tab is selected therefore still protects the server draft.
The standalone Servers window has its own session and close protection. The
existing Jobs close guard is shared without changing its delegate-forwarding
behavior.

Saving checks the baseline against the currently persisted profile before any
write. Changed or removed profiles leave the draft intact and request Revert.
Password changes rotate the profile's credential reference in the existing
persistence transaction, so they also invalidate stale drafts. No extra uncached
Keychain read or new credential persistence mechanism was introduced.

Cancelling a list selection refreshes only the list identity, restoring AppKit's
selection so that choosing the same row again works. Protocol defaults now apply
only to explicit user protocol changes. Loading a profile with another protocol
preserves its custom port in both server settings and the job connection sheet;
the latter passes its endpoint directly to Test Connection. Saving jobs already
resolved profile values correctly; the setup/test path needed the same accuracy.

## Verification and corrections

Final combined-source unsigned hosted suite: **1,316 tests, 30 expected opt-in
skips, zero failures**, exit 0. Log: `build/server-connection-full.log`.
Four new hosted regressions cover successful/failed draft saves, stale changed
and deleted profiles, two sessions with a password-only change, and Keychain
failure/retry preserving edits. The focused five-case hosted server suite also
passes (`build/server-editing-focused-final.log`).

Final unsigned arm64 Release build passes, exit 0
(`build/server-connection-release.log`). Its bundled-model verification, the
security and development-identity guards, and diff whitespace checks pass.
The final six-case native test source compiles in the signed build-for-testing
configuration (`build/server-connection-ui-build.log`). Strict DEBUG signature
and bundled-model verification pass; test compilation is not UI execution.
Independent final source/evidence review found no source blocker and explicitly
retained the pending native interaction gate.

Signed native runs found and guided fixes for two actual issues: a close guard
inside the inactive tab detached, and cancelling a server selection left AppKit
holding the declined row selection. The corrected hidden-tab close/save/reopen,
draft/tab/Add/Discard, deletion and existing Jobs close/reopen cases each have
passing evidence in `build/server-editing-native-final.log`. That selection was
not wholly passing: its remaining selection test exposed the cancelled-row issue.

`build/server-selection-port.log` then reached the expected Cancel → same row →
Save → switch-back behavior, but its final port assertion failed because the
locale displays a grouping space. The test now compares numeric digits. Review
also corrected that test to switch between different protocols rather than two
FTP profiles. A separate new job-sheet case checks a saved FTP profile on port
2121 selected from an FTPS draft, without making a network request.

The subsequent combined native run (`build/server-editing-acceptance.log`) was
interrupted by the shared desktop. Its log explicitly identifies a Media
Converter window covering the Jobs close action. The coordinator stopped only
this thread's xcodebuild (exit 75); the other app was untouched. The hidden-tab
close case passed before that interruption. This run is **not** a passing native
selection. Desktop timing was requested before further native interaction.

## Authorized native rerun

After the user confirmed desktop availability, all six signed native cases pass
together with zero failures or skips (187.6 seconds of test execution, exit 0).
Log and results: `build/server-setup-authorized-native.log` and
`build/server-setup-authorized-native.xcresult`. This tests the committed setup
source at `6ad6aaa`, plus the in-progress grouped processed-handoff engine change;
the latter is not exercised by these configuration-only fixtures.

The selection includes the three new server-draft cases,
`testJobConnectionKeepsCustomPortWhenSelectingDifferentProtocolProfile`, the
existing server deletion case and `testJobsWindowReopensFromStatusMenuAfterClosing`
under `AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests`, using the signed
`AagedalFTPSyncUISmokeTests` scheme, `build/continuation-tests` derived data and
`-parallel-testing-enabled NO`.

The job-sheet screenshot was exported and visually inspected: the selected
profile, read-only custom port 2121, remote-folder field, Test Connection and
Done are visible and legible. Fixture credentials are empty; no connection is
made to the `.invalid` host. Earlier interrupted/failed runs remain historical
and are not counted as passes.

## Limits and next actions

The focused setup interaction gate is complete for this source. This slice does
not verify real Keychain failure UI, VoiceOver,
macOS 14, original camera sidecars, interrupted publication, production performance
or a final signed release candidate. The historical candidate remains IMPLEMENTING;
M5 and final acceptance remain open. Private checklist results and candidate
records were not changed.
