# Quick file age and automatic cleanup — 2026-10-18

## Reproduction

On base `e4314cc` plus pending setup changes, a valid cleanup-enabled job could
choose Any age in menu Quick Controls. Unlike the full job editor, the menu did
not restrict that combination. AppStore persisted it without validation, leaving
the job with no required source age window. Subsequent sync admission rejects
the job's invalid configuration; this is a sync availability defect, not evidence
of incorrect file deletion.

A hosted regression reproduced four failed assertions: both in-memory and saved
jobs changed, the resulting job failed validation, and no actionable alert was
shown. Log: `build/cleanup-any-age-reproduction.log`, expected exit 65.

## Change

The menu slider starts at Last hour while automatic cleanup is enabled and
explains how to choose Any age by turning cleanup off in Job Settings. It uses
the current saved job, updates untouched open controls when saved age/cleanup
changes, and bounds its displayed/committed selection during ongoing edits.

AppStore independently rejects Any age for a cleanup-enabled job, preserves its
saved settings, and reports: “Turn off automatic cleanup in Job Settings before
choosing Any age.” Valid positive-age changes retain the existing automatic
adjustment that keeps cleanup older than the source window. Any age remains
available when cleanup is off.

Three new hosted tests cover rejection without changing the job, permitted Any
age without cleanup, below/equal/above cleanup boundary changes, and an injected
persistence failure preserving the previously published settings. Temporary local
fixtures and fake credentials are used; no user files or passwords are touched.
Independent source/test review found no blockers.

## Verification

- Focused AppStore persistence suite: 21 tests, zero failures or skips;
  `build/cleanup-any-age-focused.log`.
- Full combined-worktree hosted target: 1,339 tests, 30 expected opt-in skips,
  zero failures, exit 0, 45.877 seconds; `build/cleanup-any-age-hosted.log`.
- Signed native test compilation passes; `build/cleanup-any-age-ui-build.log`.
- Unsigned arm64 Release build and bundled-model verification pass;
  `build/cleanup-any-age-release.log`.
- Security baseline, development identity 3.0.0 (44), and diff whitespace checks pass.

The combined worktree includes pending setup changes. Native menu interaction,
Jobs/setup/reset acceptance and the broader 3.0 release gates remain open. No
desktop testing was attempted, following the user's requested wait.
