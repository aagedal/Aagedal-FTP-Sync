# Camera RAW recovery through Metadata Programming — 2026-10-17

## Scope

Continuation branch: `t3/babysit-pull-request`, based on merged `4dc1e89`.
This slice extends the existing signed native Programming recovery fixture to
Sony ARW and Canon EOS R1 CR3, through both the full-file and matching-clip
publication actions, in ordinary and managed destinations. Only test support
and native assertions change; shipping processing and recovery are unchanged.
The tracked Release candidate remains historical and IMPLEMENTING. No private
checklist results file was present in this worktree.

Both Programming actions first encounter a retained transaction and refuse
publication. Cancellation preserves visible files. Explicit test-assisted
reconciliation retains the manifest and original fixture evidence outside the
admission scan. Retry preflight must remain read-only; publication must preserve
RAW bytes and dates and source XMP while updating destination City, and the
matching clip must also publish its Headline. Existing XMP GPS remains authoritative
under the standard fill-empty GPS policy, so both RAW scopes resolve City to
Recovery Venue rather than the scheduled Oslo position. Rich generated XMP description,
keywords, copyright, rating and unknown namespace attributes must survive.
A further relaunch checks the full-file review for receipt idempotence.

Scoped RAW scheduling uses the source-modification policy with matching
09:30 filesystem timestamps, without editing the camera file. Since source
fixtures are flat and destination images are nested, scheduling uses the
existing destination-mtime fallback. JPEG scoped coverage retains its original
embedded camera-capture scheduling path.

## Environment and fixtures

arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a).
Apple Development signed isolated DEBUG app, 3.0.0 (44):
`build/continuation-tests/Build/Products/Debug/Aagedal FTP Sync.app`.
Authorized disposable RAW copies were staged from the earlier ignored DEBUG
app bundle, then the new bundle was re-signed and strictly verified.
No original photos or companion application state were changed.

Sony ARW SHA-256:
`4ceb7e1b59737362d0b3aa16fa04c3461f59bd4acb9e277be47eb61f054936dd`.
Canon CR3 SHA-256:
`c915aeb4a660f4030c37fb2a45e882bb20fc280c68316a6eb329ecf2988f0484`.
XMP is rich generated fixture content, not original camera sidecars.

## Verification

The second 12-case native run passed all eight new RAW cases and both managed
JPEG regressions, but the two ordinary JPEG cases failed accessibility snapshot
lookup during context-menu or Programming-button interaction. A competing
Media Converter native UI test run was observed after those failures; the
shared desktop was no longer isolated. After that competing run finished, both
ordinary JPEG cases passed on targeted retry (2/2, zero skips/failures, 93.298 s,
exit 0), without source changes. Thus all 12 selected cases have passing evidence
on the corrected build, across the 12-case run plus isolated retry; a single
uninterrupted all-12 pass is not claimed. The corrected 12-case run took
609.379 s and exited 65 due to the two JPEG automation failures.

The initial 12-case run passed
eight cases and failed four scoped RAW cases solely because the test expected
scheduled Oslo despite existing XMP GPS. The production fill-empty behavior was
correct; the test now expects Recovery Venue and explicitly checks retained XMP
latitude/longitude. The existing scoped JPEG fixture replaces its entire EXIF
block when adding capture time, so its scheduled Oslo expectation remains valid.

An additional CUA app observation timed out with `timeoutReached` without
returning UI state. Desktop inventory succeeded; no additional CUA observation
pass is claimed.

Focused `LocalMatchingPublicationTests`
executes 33 tests with four expected opt-in skips, zero failures, exit 0.
Signed native build-for-testing and final rebuild pass. Development identity,
security baseline and diff whitespace guards pass.

The initial sandbox build could not write Xcode compiler/package caches; the
approved build reused the existing pinned package cache without changing
versions. Desktop inventory succeeded before native testing. Other observed
Photo Agent unit tests and Media Player builds used separate derived-data roots;
no competing native UI runner was observed.

Logs:

- `/private/tmp/aftpsync-programming-raw-build.log`
- `/private/tmp/aftpsync-programming-raw-build-final.log`
- `/private/tmp/aftpsync-programming-raw-unit.log`
- `/private/tmp/aftpsync-programming-raw-ui.log`
- `/private/tmp/aftpsync-programming-raw-build-retry.log`
- `/private/tmp/aftpsync-programming-raw-ui-final.log`
- `/private/tmp/aftpsync-programming-jpeg-retry.log`

Result bundles (relative to this worktree):

- Hosted: `build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.17_17-23-49-+0200.xcresult`
- Initial native: `build/continuation-tests/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.10.17_17-24-53-+0200.xcresult`
- Corrected native: `build/continuation-tests/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.10.17_17-37-04-+0200.xcresult`
- Isolated JPEG retry: `build/continuation-tests/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.10.17_17-50-56-+0200.xcresult`

Independent read-only review found no blocking issue and confirmed existing-GPS
precedence behind the corrected City expectation. The review identified the
single-candidate scope, destination timestamp fallback and placeholder-transaction
limits recorded below. No source changes followed the corrected native build.

## Reproduction

Follow the isolated build, fixture-staging and signing procedure in
[the earlier RAW report](2026-10-09-M5-Unpublished-RAW-Recovery.md).
Use this worktree's `build/continuation-tests` derived-data directory and the
existing pinned package cache. Run hosted tests before staging, then build the
smoke scheme, stage `UITestRecovery.arw` and `UITestRecovery.cr3`, re-sign and
strictly verify. Never stage private media in a Release candidate.

Set `TEST_RUNNER_AAGEDAL_NATIVE_RAW_RECOVERY=1`, disable parallel UI testing and
run `test-without-building` with scheme `AagedalFTPSyncUISmokeTests`. Select the
following methods under `AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests`:

- `testProgrammingPublishesCameraRawAfterRecovery`
- `testManagedProgrammingPublishesCameraRawAfterRecovery`
- `testProgrammingPublishesMatchingClipCameraRawAfterRecovery`
- `testManagedProgrammingPublishesMatchingClipCameraRawAfterRecovery`
- `testProgrammingPublishesCanonRawAfterRecovery`
- `testManagedProgrammingPublishesCanonRawAfterRecovery`
- `testProgrammingPublishesMatchingClipCanonRawAfterRecovery`
- `testManagedProgrammingPublishesMatchingClipCanonRawAfterRecovery`

The invocation also selects all four existing Programming JPEG publication
regressions. Camera tests skip without explicit opt-in; missing opted-in bundled
fixtures fail. Build and test commands otherwise match the earlier report.

## Limits and remaining gates

This uses the existing retained placeholder transaction, not a process kill
during RAW publication. Actual RAW interruption boundaries have separate
[evidence](2026-10-17-M5-Prepared-RAW-Recovery.md).
Each scoped test has one matching image and does not prove exclusion of other
clips or multi-image partial publication. Original rich camera sidecars,
conflict batches, ordinary-sync interruption, VoiceOver, macOS 14 runtime,
controlled enriched performance, companion native interchange and full signed
Release acceptance remain open. This focused DEBUG evidence does not close
M5 or establish readiness for user acceptance.
