# Jobs sidebar draft selection — 2026-10-18

## Change prepared

Work on `t3/stabilize-v3-ui`, based on `d660514`. Cancelling an unsaved job
transition previously left the Jobs List identity unchanged, the same declined
selection pattern exposed by the signed server-setup tests. AppKit can keep the
proposed row selection while the binding still points to the open draft. Clicking
the same target again can then fail to request another transition.

Cancel now refreshes only the Jobs List identity from its existing selection
binding, including when the current job is an unsaved new draft. The editing
session and draft stay intact. Existing saved-job selection restoration remains.
No save, discard or transfer behavior is changed.

Two new native regressions are prepared:

- New job: edit its name, choose the saved row, Cancel, verify the draft remains,
  choose that same row again, Discard Draft, verify the saved job returns.
- Saved job: create a second job, edit it, choose the first row, Cancel, verify
  edits remain, choose that same row again, Save Changes, switch back and verify
  the saved name.

Confirmation actions are scoped to the Jobs sheet to avoid matching the editor's
Discard Draft button or Touch Bar controls. Independent read-only review found
no source blocker and identified the button-scoping correction.

## Verification status

The complete unsigned hosted target passes **1,321 tests, 30 expected opt-in
skips, zero failures**, exit 0 (44.943 seconds):
`build/jobs-selection-hosted.log`.

The signed native build-for-testing passes, exit 0:
`build/jobs-selection-ui-build.log`. This is compilation evidence only.

The unsigned arm64 Release build and its bundled-model verification pass:
`build/jobs-selection-release.log`. Diff whitespace checks pass.

The later combined shared-server refresh source also passes the full hosted
target (1,329 tests, 30 expected skips, zero failures) and signed native test
compilation. See [combined evidence](2026-10-18-Live-Shared-Server-Refresh.md).

**Native interaction is pending.** The user explicitly requested waiting before
using the shared desktop. Neither new native case has been run, so this change
does not yet have a native acceptance pass. Do not count the hosted suite or
successful native compilation as proof that AppKit selection is corrected.

Host: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), development identity
3.0.0 (44). Supported-OS/VoiceOver and the broader 3.0 release gates remain open.
