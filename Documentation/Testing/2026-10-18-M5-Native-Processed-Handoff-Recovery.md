# Native processed-handoff recovery — 2026-10-18

## Scope

Work on `t3/stabilize-v3-ui`, based on `7f114be`, with three Swift test/fixture
files modified during verification. Host: arm64 macOS 27.0.1 (26A434), Xcode
27.0 (27A266a), development identity 3.0.0 (44).

The preceding change made processed copies durable grouped publications. This
follow-up adds DEBUG-only crash/reconciliation fixtures and native acceptance
coverage; it does not change production publication or recovery behavior.

Three signed native cases kill the isolated app with SIGKILL at `published-0`
inside managed Processed Files: generated JPEG, Sony ARW/generated XMP and Canon
CR3/generated XMP. The complete Synced Files output already exists at this point.
For RAW, the processed RAW is visible while the companion XMP remains staged.

Repeated Sync Now admission rejects retained recovery, records another failure,
and preserves source, synced and recovery bytes/dates/inodes, directory membership
and processing journals. Explicit test-assisted reconciliation validates source
seeds, fixed paths, manifest and the complete synced outputs before moving the
partial publication and whole transaction aside with exclusive moves. It retains
all evidence and leaves synced outputs unchanged. This is a fixture-only recovery
choice, not production automatic recovery or a completed recovery UI.

The subsequent retry verifies metadata, RAW integrity, dates, complete processed
outputs and source removal. That first retry may republish Synced Files because
the killed run did not commit its receipt. A later idle relaunch transfers zero
files and preserves fresh output/evidence bytes, dates and inodes.

## Verification

All four selected signed native tests pass together, **zero failures or skips**,
exit 0, 211.093 seconds:

- Sony ARW managed processed handoff: 52.550 seconds.
- Canon CR3 managed processed handoff: 60.288 seconds.
- Existing managed ordinary-publication JPEG regression: 56.347 seconds.
- Managed processed-handoff JPEG: 41.907 seconds.

The user authorized this shared-desktop run after build checks. No desktop
interruption prevented the run. Result: `build/native-processed-handoff.xcresult`;
log: `build/native-processed-handoff.log`.

The complete unsigned hosted target passes **1,321 tests, 30 expected opt-in
skips, zero failures**, exit 0 (37.654 seconds), including two new reconciliation
tests. Those check byte/date/inode preservation and idempotence, plus eight invalid
evidence combinations rejected before any move. The focused publication suite
also passes all 13 tests. Logs: `build/native-handoff-hosted.log` and
`build/native-handoff-fixture-focused.log`.

The signed UI build passes (`build/native-handoff-ui-build.log`). The staged DEBUG
app passes strict signature and bundled-model verification. Security dependency
and development-identity guards pass. Independent final source review found no
blocker in the reconciliation safeguards or preservation assertions.

The final unsigned arm64 Release build passes, exit 0
(`build/native-handoff-release.log`), and its bundled-model verification passes.
The Release app contains no staged camera test fixtures.

## Authorized fixtures

Previously authorized camera copies were reused from the explicit sibling
`t3-8824d8cc` DEBUG fixture bundle, hash-checked before and after copying into this
worktree's ignored DEBUG app resources, then the DEBUG app was re-signed. No
camera files were added to the repository or Release resources.

SHA-256:

- ARW: `4ceb7e1b59737362d0b3aa16fa04c3461f59bd4acb9e277be47eb61f054936dd`
- CR3: `c915aeb4a660f4030c37fb2a45e882bb20fc280c68316a6eb329ecf2988f0484`
- Tested DEBUG executable: `8fa5a266a4208510787530b1220740819caad43a59ec9c528d6ed255bab4b2c6`

Camera sidecars are generated fixtures, not original camera sidecars. JPEG is
generated. Native tests use only their isolated app data and local folders.

## Remaining gates

M5 remains open. Custom processed-root native interruption, other crash boundaries,
ordinary replacement, multi-image scoped batches, original camera sidecars,
controlled throughput, supported macOS/VoiceOver, production recovery UX and
final-candidate acceptance are not established by this selection. The historical
candidate remains IMPLEMENTING.
