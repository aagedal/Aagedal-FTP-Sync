# Photographer close decisions and autosave — 2026-10-18

## Reproduction and fix

The photographer close guard introduced at `ee84c02` cancelled pending autosave
before presenting its close decision. Cancel correctly kept the window open but
did not restore that pending task. A valid edited profile could remain dirty with
Saving displayed until another edit or explicit save action.

An injected close choice exercises the actual decision handler without creating
or presenting an NSAlert. Before the fix, the pending-autosave/Cancel regression
failed four assertions: the saved copyright stayed old, the session remained
dirty, and Saved was not reached or preserved after refresh. See
`build/photographer-close-cancel-reproduction.log`, expected exit 65.

The guard now remembers whether autosave was pending before pausing it for the
decision. Cancel restores only that existing autosave with a fresh debounce.
Discard leaves it cancelled and adopts the latest saved profile. A failed Save
leaves the draft and error available for explicit retry. A previously paused
conflicting or failed draft does not acquire a new autosave merely from Cancel.
The save-time baseline guard continues to reject external changes.

## Verification

The focused editing/library selection passes 14 tests with zero failures/skips,
exit 0, 4.000 seconds (`build/photographer-close-focused.log`). Tests cover pending
Cancel followed by autosave, Discard with an external update during review,
Cancel without a pending conflicting save, and failed close-save without a
delayed retry after storage is repaired. Discard assertions also check the saved
file identity to detect an unwanted timer rewriting an identical restored value.
The successful autosave's Saved status survives its own library notification.

The final combined-worktree hosted target passes 1,350 tests with 30 expected
opt-in skips and zero failures, exit 0, 50.041 seconds
(`build/photographer-close-hosted.log`). Signed native test compilation passes
(`build/photographer-close-ui-build.log`), as do the unsigned arm64 Release build
(`build/photographer-close-release.log`), bundled-model verification, security
baseline, development identity 3.0.0 (44), and diff whitespace checks. Independent
final review found no blockers.

All stores/credentials are test fixtures. Decision injection verifies scheduling and persistence behavior; it does
not establish native modal appearance, focus, keyboard controls or window closure.
No desktop interaction was attempted, following the user's requested wait.
The combined worktree retains pending setup changes, and native/release acceptance
remains open.
