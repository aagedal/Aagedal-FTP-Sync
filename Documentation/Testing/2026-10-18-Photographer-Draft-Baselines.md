# Shared photographer draft baselines — 2026-10-18

## Finding

On base `c8e685f` plus pending setup changes, both Settings/Photographers and the
standalone Photographers window instantiated independent editors. Dirtiness was
computed by comparing the draft directly with the live library. Updating the
profile in another window therefore made an untouched stale draft appear dirty.
The library observer skipped refresh, and disappearance could save the stale
profile over the newer shared profile and linked job copies. A genuinely edited
draft also had no saved-baseline check before its delayed autosave.

This path was confirmed by independent source review. It was not reproduced in
native windows because the user's desktop wait remains in force.

## Change

`PhotographerEditingSession` retains the persisted baseline separately from the
draft. Clean external changes refresh the draft without creating unsaved edits
or another write. Dirty external conflicts retain local edits and reject saving
against a changed or deleted baseline, including a delayed callback before the
view's observer runs. A deleted profile cannot be recreated by stale autosave.

The session owns the existing 600 ms autosave task, cancels it on refresh/revert
or before a close decision, and adopts the actual normalized persisted profile
after a successful save. Failed saves retain the draft and show an actionable
error with Revert and retry controls instead of an indefinite Saving status.
Unchanged refreshes preserve the successful Saved indicator.

Settings owns the session across tab removal and includes it in its existing
aggregate close guard. The standalone window has its own guard. Dirty sessions
survive reappearance without being reloaded by the selected-ID observer. Closing
with unsaved edits offers Save Changes, Discard Changes and Cancel; the guard
does not allow a failed save to close the window.

## Verification

Four new hosted regressions cover clean two-editor refresh, dirty conflict and
pending-autosave cancellation, external deletion without recreation, and injected
persistence failure followed by successful retry. Tests inspect saved library
state and linked job copies, using isolated local stores and fake credentials.
The focused editing/library selection passes 12 tests with zero failures/skips
(`build/photographer-draft-focused.log`). Independent final review found no blockers.

The full combined-worktree hosted target passes 1,348 tests with 30 expected
opt-in skips and zero failures, exit 0, 43.749 seconds
(`build/photographer-draft-hosted.log`). Signed native test compilation passes
(`build/photographer-draft-ui-build.log`), as do the unsigned arm64 Release build
(`build/photographer-draft-release.log`), bundled-model verification, security
baseline, development identity 3.0.0 (44), and diff whitespace checks.

The combined worktree includes pending setup changes. Native simultaneous-window,
tab switching, modal close choices, status layout and keyboard/VoiceOver acceptance
remain unverified. No desktop interaction was attempted; broader 3.0 release gates
remain open.
