# Metadata operation reservation — 2026-10-18

## Reproduction and fix

On `t3/stabilize-v3-ui`, base `d660514` plus pending reset/setup changes,
metadata work registers a per-job task before waiting for a global concurrency
slot. Manual Sync Now already respects that busy reservation. Scheduled sync
previously checked only the running lock and could queue more work for the same
job while metadata preflight/reprocessing was already waiting.

The existing execution lock prevents simultaneous writes. This defect concerns
competing queue admission, operation priority and unnecessary slot consumption;
the regression does not demonstrate concurrent file mutation.

The new regression holds the global slot, queues metadata work, invokes menu
Start/Start All and the scheduler delegate, and requires scheduled sync to return
skipped while only metadata waits. Before the fix, both preflight and reprocessing
variants reproduced **three pending requests instead of one**, with the sync call
still waiting at the one-second observation boundary. Cleanup cancelled and
drained all paths; no test host or fixture operation was left running.
Log: `build/metadata-reservation-reproduction.log`, expected failing test, exit 65.

Scheduler admission now checks the registered metadata task before requesting a
slot and again after acquisition. It skips the attempt until that reservation
drains; normal automatic scheduling remains enabled for later checks. It does
not use the general busy predicate, which includes the scheduler's own task and
would reject legitimate scheduled sync.

The regression also cancels/drains the metadata reservation and confirms that a
fresh preflight reaches its ready result. Existing queued cancellation, lease
cleanup, manual sync and reset exclusion tests remain in the full suite.
Independent source/test review supports the reservation rule and found no
regression-test blocker.

## Scope

The final combined hosted target passes **1,332 tests, 30 expected opt-in skips,
zero failures**, exit 0 (46.598 seconds): `build/metadata-reservation-hosted.log`.
The signed native build-for-testing passes (`build/metadata-reservation-ui-build.log`),
as do the unsigned arm64 Release build (`build/metadata-reservation-release.log`),
bundled-model verification and security/development-identity guards. These are
build/hosted checks, not native interaction acceptance.

This change adds two scheduler admission checks and one hosted regression. It
does not change metadata publication, source-removal or rollback policy. The
earlier reset fixes are part of the combined source under verification.

Host: arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), development identity
3.0.0 (44). Pending setup source remains modified. No desktop interaction was
attempted, following the user's requested wait. Native setup/reset, supported-OS,
VoiceOver, remaining M5 and final-candidate acceptance remain open.
