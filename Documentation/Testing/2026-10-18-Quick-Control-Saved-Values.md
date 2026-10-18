# Quick controls show saved settings — 2026-10-18

## Findings and changes

On base `1c23055` plus pending setup source, menu sliders retained their local
value after a rejected persistence operation. AppStore correctly kept the old
settings, but no saved-value change fired the file-age observer; the interval
slider also had no saved-value refresh. The controls could therefore show a
setting that was never saved. This was established from the binding/save flow;
native failure-display reproduction remains pending desktop availability.

The menu now reads the saved job directly while idle and uses local state only
during an edit. It captures the requested file age before returning to idle,
attempts the synchronous store update, and then shows the store's actual value
after either success or failure. Interval controls follow the same saved-versus-
editing rule. Binding setters also mark changes pending, preserving changes made
through the slider binding even before an editing callback.

The previous fixed age options also had no entry for valid custom saved values
such as two hours: the menu fell back to Any age and setup had no matching picker
tag. Both editors now use shared choices containing the saved custom window once,
in order, and shared labels. A fourteen-day saved window extends the menu range
with an accurate endpoint caption. Choices freeze while dragging so an external
custom-age update cannot change the meaning of an ordinal slider position.
Cleanup restrictions and AppStore persistence behavior remain in force.

## Verification

One new hosted regression saves and reloads two-hour and fourteen-day windows,
checks exact selectable choices and labels, and confirms that preparing choices
does not change saved settings. Existing failed-save coverage now also verifies
that a failed interval save preserves the stored job, alongside the file-age and
cleanup assertions. The focused AppStore persistence suite passes 22 tests with
zero failures or skips (`build/quick-controls-saved-display-focused.log`).

Independent source/test review found no blockers, including callback ordering,
captured commits, frozen options and failed saves. The full combined-worktree
hosted target passes 1,340 tests with 30 expected opt-in skips and zero failures,
exit 0, 45.428 seconds (`build/quick-controls-saved-display-hosted.log`). Signed
native test compilation passes (`build/quick-controls-saved-display-ui-build.log`),
as do the unsigned arm64 Release build (`build/quick-controls-saved-display-release.log`),
bundled-model verification, security baseline, development identity 3.0.0 (44),
and diff whitespace checks.

The combined worktree includes pending setup changes. Native slider gestures,
keyboard interactions, open-popover refresh and failed-save display remain
unverified; no desktop interaction was attempted following the user's wait.
These hosted/source checks do not close native UI or final 3.0 release gates.
