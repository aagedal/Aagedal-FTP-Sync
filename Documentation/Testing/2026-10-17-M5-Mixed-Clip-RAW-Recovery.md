# Mixed-clip camera RAW recovery — 2026-10-17

## Scope and fixtures

Continuation branch: `t3/continue-plan-1`, based on merged `90a60bb`.
This slice extends the retained-transaction Programming fixture with a second
image assigned to another clip. Shipping processing/recovery behavior and the
historical Release candidate identity are unchanged. No private checklist results
file was present in this worktree.

Four opt-in native cases cover Sony ARW and Canon EOS R1 CR3, each in ordinary
and managed destinations. Both images use the same `MAP` photographer prefix
and the same day, with 09:30 and 11:30 filesystem modification times. Two clips
cover 09:00–10:00 and 11:00–12:00 with distinct Headlines. This exercises clip
membership beyond photographer/day filtering. As with the earlier fixture,
source images are flat and destination images nested; source-modification
scheduling uses the existing destination-time fallback.

Both Programming entry points first reject retained recovery state. After
explicit test-assisted reconciliation, scoped preflight checks exactly one
image, remains read-only, and publishes only the selected clip. The other
image's source/destination RAW and XMP bytes and modification dates must remain
unchanged through blocked admission, cancellation, reconciliation, preflight,
publication, relaunch and a later full-file review. Initial snapshots are also
checked against the seeded pair bytes and the expected other-clip timestamp.

After relaunch, scoped preflight must check one image with zero ready, proving
receipt idempotence for the selected clip. The following full-file review must
check two images and offer exactly one update, proving the other clip remains
eligible. Canceling this review must leave it untouched. Existing assertions
continue to cover selected RAW/source integrity, preserved dates, rich XMP
fields and GPS, selected Headline, retained manifest and original fixture bytes.

## Environment

arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a).
Apple Development signed isolated DEBUG app, 3.0.0 (44):
`build/continuation-tests/Build/Products/Debug/Aagedal FTP Sync.app`.
The app uses disposable RAW copies from the previously authorized ignored DEBUG
bundle and is re-signed and strictly verified after staging. No operator photos
or companion application state are changed.

Sony ARW SHA-256:
`4ceb7e1b59737362d0b3aa16fa04c3461f59bd4acb9e277be47eb61f054936dd`.
Canon CR3 SHA-256:
`c915aeb4a660f4030c37fb2a45e882bb20fc280c68316a6eb329ecf2988f0484`.
Sidecars are rich generated XMP, not original camera sidecars.

## Verification

The single signed native run passes all eight selected cases, with zero skips or
failures in 447.888 seconds, exit 0. This includes all four new mixed-clip cases,
ordinary ARW and managed CR3 single-image scoped publication regressions, and
both scoped JPEG regressions. The final assertion build was tested without any
subsequent Swift source changes. The tested source is base `90a60bb` plus the
committed fixture/assertion diff in this report's commit; only documentation was
edited after native verification.

The tests confirm exact one-image scoped preflight/publication, preserved excluded
RAW/XMP source and destination bytes/dates, preserved selected-image rich XMP/GPS
and RAW integrity, scoped receipt idempotence across relaunch, and exactly one
remaining update in a two-image full-file review. Canceling that full review
preserves both clips. Independent read-only review found no blocking issue;
its initial-snapshot coverage observation was addressed before the final build.

The focused `LocalMatchingPublicationTests` suite executes 33 tests with four
expected opt-in skips and zero failures, exit 0. Signed native build-for-testing
and the rebuild with strengthened initial integrity assertions both pass.
Development identity, security baseline and diff whitespace guards pass.

The initial sandbox invocation could not write the pinned package/Swift compiler
caches; the approved invocation reused the existing cache without version changes.
Desktop inventory succeeded. A competing Photo Agent native test was detected
before starting this run, so native verification waited for that runner to finish.
The coordinators explicitly reserved the next quiet desktop window; this run
started at 18:17:17 CEST, finished at 18:24:45, and released the desktop after
runner/app termination. No additional CUA app observation or VoiceOver pass is
claimed.

Logs:

- `/private/tmp/aftpsync-mixed-clip-unit.log`
- `/private/tmp/aftpsync-mixed-clip-build.log`
- `/private/tmp/aftpsync-mixed-clip-build-final.log`
- `/private/tmp/aftpsync-mixed-clip-ui.log`

Result bundles, relative to this worktree:

- Hosted: `build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.17_18-07-20-+0200.xcresult`
- Native: `build/continuation-tests/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.10.17_18-17-16-+0200.xcresult`

## Reproduction

Follow the isolated build, DEBUG fixture staging and signing procedure in
[the earlier RAW report](2026-10-09-M5-Unpublished-RAW-Recovery.md), using this
worktree's `build/continuation-tests` directory. Run hosted tests before staging
media, then build the native scheme, stage the two authorized fixture copies,
re-sign and strictly verify. Never stage private media in a Release candidate.

Set `TEST_RUNNER_AAGEDAL_NATIVE_RAW_RECOVERY=1`, disable parallel UI testing,
and run `test-without-building` with scheme `AagedalFTPSyncUISmokeTests`.
Select these methods under `AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests`:

- `testProgrammingRecoveryExcludesOtherClipCameraRaw`
- `testManagedProgrammingRecoveryExcludesOtherClipCameraRaw`
- `testProgrammingRecoveryExcludesOtherClipCanonRaw`
- `testManagedProgrammingRecoveryExcludesOtherClipCanonRaw`

The selected regression run also includes ordinary ARW and managed CR3
single-image scoped publication and both ordinary/managed scoped JPEG cases.
Camera tests skip without explicit opt-in; a missing opted-in fixture fails.

## Limits and remaining gates

This is a retained placeholder transaction, not a process kill during mixed-batch
publication. It covers selecting one image from two clips, not partial success
within a multi-image selected clip. Edited-output conflicts, original rich camera
sidecars, multi-image/partial-batch interruption, ordinary-sync interruption,
VoiceOver, macOS 14 runtime, controlled enriched performance, companion native
interchange and full signed Release acceptance remain open. This focused DEBUG
slice does not close M5 or establish readiness for user acceptance.
