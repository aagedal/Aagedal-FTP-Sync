# Reviewed RAW output conflicts after recovery — 2026-10-17

## Scope and source

Continuation branch: `t3/continue-plan-2`, based on merged `b0cbd76`.
This slice adds four opt-in native UI cases to the existing mixed-clip retained
recovery fixture. Only DEBUG fixture plumbing, UI test source and acceptance documentation change.
No private local checklist results file was present in this worktree.

Sony ARW and Canon EOS R1 CR3 are each exercised in ordinary and managed
folders. The selected image first passes blocked recovery admission through
full-file and clip-scoped Programming, explicit test-assisted reconciliation,
scoped publication and relaunch idempotence. A second image shares the
photographer/day but belongs to another clip and remains eligible for a later
full-file review.

The native runner cannot write within the app container. Explicit DEBUG-only
controls in the review sheet perform the fixed-path fixture edits in the app;
they require UI isolation, mixed-clip/RAW fixture flags, the edit opt-in and a
reconciled transaction. The runner independently reads and validates the result.
The new continuation removes the selected output's scheduled Headline, leaving
valid rich XMP, and adds a local-edit comment. Clip preflight must report exactly
one checked file, zero ready updates and one edited output. The ordinary action
is disabled, the explicit edited-output action is enabled, and canceling the
review preserves all files.

A second preflight is made stale by changing the XMP comment from A to B while
keeping byte count and modification time identical. Applying that old approval
must skip the selected image and preserve the later bytes. A fresh review then
explicitly approves the current revision and fills the scheduled Headline.
Relaunch must retain receipt idempotence without another conflict or ready
update. RAW source/destination bytes and dates, source XMP, excluded-clip
source/destination RAW/XMP bytes and dates, the retained transaction manifest
and rescued original remain checked throughout. Rich XMP and existing GPS are
checked after successful publication.

## Environment and fixtures

arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a).
Apple Development signed isolated DEBUG app, 3.0.0 (44):
`build/continuation-tests/Build/Products/Debug/Aagedal FTP Sync.app`.
Authorized disposable fixture copies were staged from the earlier ignored DEBUG
bundle and the new app was re-signed and strictly verified. Original photos and
companion app state are untouched.

Sony ARW SHA-256:
`4ceb7e1b59737362d0b3aa16fa04c3461f59bd4acb9e277be47eb61f054936dd`.
Canon CR3 SHA-256:
`c915aeb4a660f4030c37fb2a45e882bb20fc280c68316a6eb329ecf2988f0484`.
Sidecars are generated rich XMP, not original camera sidecars.

## Verification

The final signed native invocation passes all six selected cases with zero
failures or skips in 600.122 seconds, exit 0. It includes all four new conflict
cases and ordinary ARW/managed CR3 mixed-clip regressions. The corrected source
was built before this run, with no subsequent Swift changes. All four conflict
cases verify canceled review, preservation after a same-size/same-time later
edit, rejection of stale approval, successful fresh approval and relaunch
idempotence. This is a single clean selected run after the harness correction.

The final focused hosted selection passes 67 tests with five
expected opt-in skips and zero failures (exit 0): 34 activated metadata integration
cases and 33 local matching publication cases. Signed UI build-for-testing,
development identity, security baseline, diff whitespace and bundled AuraFace
verification pass. Independent read-only source review found no blockers; its
suggested rescued-original and post-approval GPS assertions were incorporated
before compilation. A second read-only review of the fixture-edit correction
also found no blockers.

The initial restricted build failed on package/compiler cache writes outside
writable roots. The approved retry reused the existing pinned dependency cache;
no package versions changed. Re-signing by certificate display name was ambiguous
because two valid development identities share the name; signing by the exact
valid certificate hash succeeded, followed by strict signature verification.
The first native invocation passed its mixed-clip regression, then failed the
new case because the runner lacked permission to write the disposable app
container (NSCocoaErrorDomain 513). It was stopped (exit 75), and the edits were
moved to the explicitly gated DEBUG fixture controls before rebuilding.
Desktop inventory succeeded. A Photo Agent hosted-test build was active in a
separate derived-data directory, but no competing native UI runner was active
when the initial native run started. Before retry, a Media Player native validation
was active; the corrected run waited for its coordinator to release the desktop.
An optional unsigned Release compilation was started while waiting, then stopped
to reduce load during the other task's performance measurements; it supplies no
Release validation evidence. No other app was controlled.

Logs:

- `/private/tmp/aftpsync-conflict-unit.log`
- `/private/tmp/aftpsync-conflict-build.log`
- `/private/tmp/aftpsync-conflict-ui.log` (initial harness failure)
- `/private/tmp/aftpsync-conflict-unit-final.log`
- `/private/tmp/aftpsync-conflict-build-final.log`
- `/private/tmp/aftpsync-conflict-ui-final.log`

Hosted result:
`build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.17_20-07-25-+0200.xcresult`.
Native result:
`build/continuation-tests/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.10.17_20-19-15-+0200.xcresult`.
Xcode pruned the earlier result bundles; the initial build/test text logs remain
at the paths above. The final native run reserved the desktop after the Media
Player coordinator's release confirmation, ran 20:19–20:29 CEST, and released
it after app/runner exit. This selection is not a full smoke suite, separate CUA
workflow observation or VoiceOver acceptance pass.

## Reproduction

Follow the isolated build, authorized fixture staging and re-signing procedure
in [the earlier RAW report](2026-10-09-M5-Unpublished-RAW-Recovery.md).
Use this worktree's `build/continuation-tests` derived-data directory and the
existing pinned package cache. Run the hosted selection for
`LocalMatchingPublicationTests` and `ActivatedMetadataSyncIntegrationTests`
before staging media. Build scheme `AagedalFTPSyncUISmokeTests`, stage only the
authorized `UITestRecovery.arw` and `UITestRecovery.cr3` DEBUG resources,
re-sign preserving metadata and strictly verify.

Set `TEST_RUNNER_AAGEDAL_NATIVE_RAW_RECOVERY=1`, disable parallel testing and
run `test-without-building` with the UI smoke scheme. Select under
`AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests`:

- `testProgrammingRecoveryPreservesEditedCameraRawUntilReviewed`
- `testManagedProgrammingRecoveryPreservesEditedCameraRawUntilReviewed`
- `testProgrammingRecoveryPreservesEditedCanonRawUntilReviewed`
- `testManagedProgrammingRecoveryPreservesEditedCanonRawUntilReviewed`

The selected regression run also includes ordinary ARW and managed CR3
`ProgrammingRecoveryExcludesOtherClip` cases. Camera cases skip without explicit
opt-in; opted-in missing fixtures fail. Never stage private media in Release.

## Limits and remaining gates

This covers content-bound conflict approval after retained-placeholder recovery
and one-image clip publication. It does not establish actual process interruption
within a multi-image selected clip. Original rich camera sidecars, multi-image
partial-batch interruption, ordinary-sync interruption, VoiceOver, macOS 14,
controlled enriched performance, companion native interchange and full signed
Release acceptance remain open. The historical candidate remains IMPLEMENTING;
this focused DEBUG evidence does not close M5 or qualify a final candidate.
