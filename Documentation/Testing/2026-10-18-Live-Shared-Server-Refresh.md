# Open job connection refresh — 2026-10-18

## Defect and implementation

Work on `t3/stabilize-v3-ui`, based on `d660514`, alongside the pending Jobs
sidebar selection fix. Editing a shared server in Settings/Servers updates the
saved jobs, but an open Jobs draft previously refreshed only menu-bar controls.
Its connection sheet retained the old host, port and password. Test Connection
captured those stale values, although Save/Sync resolved the new profile.

The Jobs window now refreshes linked connection projections when the server
library changes. The editing session preserves job-local remote folders and
other edits, rebases its saved endpoint baseline, and reloads current shared
credentials. Save also refreshes before writing, covering a delayed view observer.
External changes alone do not create unsaved job edits. Custom endpoint choices
and typed custom passwords remain local.

Draft and baseline passwords are read before publishing any credential change.
They stay associated with their respective endpoint selections, so Discard
restores the correct original password. A custom password can be reloaded only
when its profile selection, credential reference and text still match the saved
baseline. Equal password text on a newly detached custom connection is preserved.
Loading errors block save and retain edits for the existing retry action.

Test Connection resolves the current shared profile and its current credential
reference when pressed. Missing profiles or password-read errors fail before the
network call. Direct custom tests use the typed draft password. Completion checks
that the current endpoint/profile/password still matches the captured input;
profile changes also cancel/reset the visible test state. This prevents an old
success, failure or SSH trust prompt being presented for a changed connection.

## Verification scope

Eight new hosted cases cover live projection/password changes without dirtying a
clean draft, local path/name/custom-password preservation, read failure/retry,
save before the view observer, custom-to-profile selection followed by discard,
profile-to-custom detachment with equal password text, current-profile test input
and invalidation including password-only rotation, and typed custom test input.

Initial focused checks exposed two unsupported remote-to-remote test fixtures;
those were corrected. Independent review identified two baseline password
association issues in the new reload path; both have dedicated regressions.
One intermediate assertion compared a pre-save credential ID to its intentionally
rotated persisted ID; the corrected regression uses the persisted baseline.
These diagnostic runs are not passing acceptance evidence.

The preceding full hosted run passed 1,328 tests, with 30 expected opt-in skips
and zero failures, before the final detachment safeguard/regression was added.
Its log is `build/live-profile-hosted.log`.

The final current-source hosted suite passes **1,329 tests, 30 expected opt-in
skips, zero failures**, exit 0 (40.733 seconds):
`build/live-profile-hosted-final.log`. Independent final source review found no
remaining blocker in the credential-baseline or test-input safeguards.

The final signed native build-for-testing passes, exit 0:
`build/live-profile-ui-build.log`. This compiles all three pending native
regressions but does not execute them. Security/development-identity and diff
whitespace checks pass.

The final unsigned arm64 Release build passes, exit 0:
`build/live-profile-release.log`. Its bundled-model verification passes, and
the Release app contains no staged camera test fixtures.

Host: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), development identity
3.0.0 (44). The two Swift view files, editing session, hosted/native test files
and documentation were modified during verification.

## Native gate

A new native case is prepared to keep the job connection sheet open, edit a shared
server port in Settings, verify the disabled job port refreshes, and retain the
job's unsaved name/remote folder through save. It makes no network connection.
Both sidebar Cancel regressions also remain pending.

The user explicitly requested waiting before using the shared desktop. No new
native interaction was attempted. Hosted tests and signed test compilation do
not establish native interaction, supported-OS or VoiceOver acceptance. M5 and
the full 3.0 candidate gates remain open.
