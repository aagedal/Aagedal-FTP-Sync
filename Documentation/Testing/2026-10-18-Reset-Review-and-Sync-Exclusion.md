# Reset review and sync exclusion — 2026-10-18

## Defects

On `t3/stabilize-v3-ui`, base `d660514` plus the pending setup fixes, review
identified two reachable reset races:

- Reset preview awaits folder planning while other job settings remain editable.
  Saving a different destination during that wait could leave confirmation
  describing folder A while Reset Job re-read the saved job and deleted folder B.
- Menu Start/Start All could enable and schedule the job while reset planning or
  cleanup was active. Manual Sync Now already checked busy state, but scheduler
  admission did not independently exclude reset, and Save could reschedule work.

## Changes

Preview now returns a `JobResetReview` containing the saved job snapshot and its
folder/count preview. The store rejects changed settings or new busy state after
the await and checks that exact snapshot again before disabling the job or
starting any deletion. Reset accepts a review rather than just a job ID.

The editor checks its current draft against the review before presenting and
confirming it, invalidates confirmation when draft/saved settings change, and
uses the reviewed folder/count without falling back to a different current job.
A refused reset no longer modifies the draft's enabled/login settings.

Start and Save are blocked while reset is registered; Start All keeps resetting
jobs stopped and reports them. Scheduler admission checks reset both before and
after acquiring its concurrency lease. The reset remains registered until file
work and history cleanup drain. The menu shows “Resetting downloads…” and disables
Start and busy Sync Now controls. Existing successful reset behavior is retained.

An optional reset-planning hook supports deterministic suspended-operation tests;
normal service construction supplies no hook. No recovery/deletion policy or
per-file rollback rule was loosened.

## Hosted verification

The focused local-sync/persistence selection passes **79 tests, zero failures or
skips**, exit 0 (6.032 seconds): `build/reset-review-focused.log`.

Two new async regressions verify:

- Destination changes both while preview is suspended and after review returns.
  Stale preview/confirmation are rejected without touching either managed folder.
  A fresh review then resets only the newly reviewed target; the old folder's
  bytes remain intact.
- An active reset held before deletion rejects Start, Start All, Save, Sync Now
  and direct scheduler admission. No endpoint session opens and download bytes
  remain unchanged during the pause. After reset drains, deletion completes and
  a fresh sync is admitted.

The existing reset/history cleanup test now obtains and confirms a real review.
The complete hosted target passes **1,331 tests, 30 expected opt-in skips, zero
failures**, exit 0 (40.371 seconds): `build/reset-review-hosted.log`.
Independent source/test review found no remaining blocker. Security dependency,
development-identity and diff whitespace checks pass.

Signed native build-for-testing passes, exit 0:
`build/reset-review-ui-build.log`. This is compilation evidence only.

The final unsigned arm64 Release build passes, exit 0:
`build/reset-review-release.log`. Its bundled-model verification also passes.

Host: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), development identity
3.0.0 (44). AppStore, reset service/models, editor/menu and integration test source
were modified, alongside the earlier pending sidebar/live-profile source.

## Native and release gates

The user requested waiting before shared-desktop use. No native interaction was
attempted for these fixes. The three prepared sidebar/live-profile native cases
remain pending, and reset confirmation wording/invalidated review, reset menu
busy state and successful reset/relaunch also need native observation. Hosted
suspension tests establish store admission, not SwiftUI/AppKit behavior.

Supported-OS/VoiceOver, remaining M5 recovery/performance, production face
acceptance and final-candidate verification remain open. The historical candidate
stays IMPLEMENTING; none of these results closes the full release gate.
