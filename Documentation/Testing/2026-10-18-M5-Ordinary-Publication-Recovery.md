# Durable ordinary local publication recovery — 2026-10-18

## Scope and source

Continuation branch: `t3/continue-existing-plan`, from merged `957b3db`.
Scheduler fix commit: `1f36f56`. Verification ran with publication/fixture Swift
changes modified, the new hosted file untracked, and documentation in progress.
No subsequent app-code changes followed the final hosted/signed builds.

The previous native Sync Now tests interrupted reprocessing and then checked
ordinary admission. Investigation found that ordinary local publication inherited
the protocol's sequential importer and temporary rollback backups: SIGKILL could
leave a partial pair without a root-local recovery marker.

Ordinary local grouped publication and collision-safe grouped publication now use
the existing durable matching transaction machinery. It supports first imports
with an empty originals array while the explicit matching API still requires
original evidence. Listed existing outputs are snapshotted directly into the
transaction before any visible mutation. Exclusive renames protect unforeseen
collisions. Rollback checks output identity and bytes; edited fresh outputs also
retain recovery, even when no old original exists. All current production callers
supply at most an image and its companion, matching the shared transaction limit.

A native run also exposed stale manual-sync UI state: the final phase update
preceded release of the scheduler's busy request, leaving Sync Now disabled.
The scheduler now notifies the store after the matching manual request is cleared.
An old cancelled request cannot issue that notification for its replacement.

The new DEBUG fixture routes ordinary local sessions through the existing crash
hook and kills at `published-0`. Native checks cover generated JPEG and opt-in
Sony ARW/Canon CR3 in ordinary and managed destinations. For RAW, the first output
is visible while enriched XMP remains staged. Repeated admission rejection must
preserve bytes, dates, inodes, directory membership and processing journals.
An explicit DEBUG-only reconciliation validates fixed paths, source bytes and the
partial layout, preserves the published member and whole transaction outside
admission, then retries from the source. Retry verifies metadata, RAW integrity,
managed processed copies/source removal, and idle relaunch without republication.
This helper is test-assisted reconciliation, not production automatic recovery.

## Verification

The final complete unsigned hosted target passes 1,308 tests, with 30 expected
opt-in skips and zero failures, exit 0 (42.414 seconds). It includes all 11 new
ordinary-publication/fixture tests and the scheduler regressions. Result:
`build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.18_14-58-44-+0200.xcresult`.
An unsigned arm64 Release build and both DEBUG/Release bundled-model
verification pass. The staged DEBUG app passes strict signature verification. Executable SHA-256:
`abf580f7115b6faafb49f299b9e6ae29df98a9aaf588a8dad047941fde041713`.
All eight selected signed native tests pass with zero failures or skips, exit 0
(335.075 seconds). They cover the six new ordinary-sync cases and both existing
JPEG reprocessing interruption regressions. Result:
`build/continuation-tests/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.10.18_15-08-45-+0200.xcresult`.

An initial native invocation was cancelled after desktop inspection revealed an
active Media Player native run. This thread's runner stopped; the final eight-case
run began only after that process exited. No unrelated task was steered or stopped.

Desktop inventory returned successfully earlier. A separate final CUA app-selection
call returned `Computer Use server error -10005: timeoutReached` after approximately
52 minutes, without UI state or input. This is not a direct CUA workflow pass.
The explicitly isolated fixture process was no longer running when checked;
a process without that fixture environment was left untouched. Native XCUITest
observations above remain the UI evidence, not VoiceOver or full smoke acceptance.

Final logs:

- `/private/tmp/aftpsync-ordinary-full-hosted-verified-final.log`
- `/private/tmp/aftpsync-ordinary-release.log`
- `/private/tmp/aftpsync-ordinary-build-signed-final.log`
- `/private/tmp/aftpsync-ordinary-signature.log`
- `/private/tmp/aftpsync-ordinary-ui-final.log`

Earlier diagnostic logs retain the signed-hosted sandbox failures, corrected
fixture-path failures, initial JPEG failure and cancelled native invocation.
The default Python interpreter also lacked the loopback helper dependencies;
no live transport rerun or new dependency installation is claimed.
The initial focused signed hosted selection passed 132 tests with five expected
opt-in skips and no failures. It preceded the scheduler fix and two additional
fixture tests. The first new native JPEG run reached interruption, blocked
admission, reconciliation, retry and idle checks, but failed two assertions
because Sync Now remained disabled; it is not counted as a pass.

The first complete signed hosted invocation was unsuitable for existing storage
and loopback fixtures: its sandbox rejects direct `/private/tmp` writes and local
listener setup. The documented unsigned hosted configuration resolves those
environment failures. Initial unsigned runs exposed alias assumptions in the new
fixture assertions; canonical parent directories and reported recovery-path
comparison fixed them before the final complete pass. One intermediate compile
retry corrected a nonthrowing XCTest error-handler annotation.

Independent read-only review identified collision diagnostic compatibility,
managed-copy/retained-evidence assertion gaps and source-validation requirements.
Those were addressed. The review also checked the simplified ordinary snapshot
path. The coordinator reviewed the delegated scheduler change and regressions. Final
independent source/evidence review found no blocking issue or readiness overclaim.

## Environment and fixtures

arm64 macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), app 3.0.0 (44).
Isolated DEBUG app: `build/continuation-tests/Build/Products/Debug/Aagedal FTP Sync.app`.
Dependencies reuse the pinned existing checkout cache; local packages resolve to
this worktree. No private checklist observations file was present.

Camera inputs are previously authorized disposable DEBUG bundle copies, never
operator originals. Sony ARW SHA-256:
`4ceb7e1b59737362d0b3aa16fa04c3461f59bd4acb9e277be47eb61f054936dd`.
Canon CR3 SHA-256:
`c915aeb4a660f4030c37fb2a45e882bb20fc280c68316a6eb329ecf2988f0484`.
XMP is generated rich metadata, not an original camera sidecar. No private media,
face libraries, credentials or local checklist entries are committed.

## Reproduction

Use the isolated build/sign/stage procedure from
[earlier RAW evidence](2026-10-09-M5-Unpublished-RAW-Recovery.md).
The hosted target uses the [documented unsigned setup](2026-09-21-M3-Canonical-Test-Paths.md)
for storage and loopback fixtures:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/continuation-tests -disableAutomaticPackageResolution \
  -only-testing:AagedalFTPSyncTests CODE_SIGNING_ALLOWED=NO
```

Rebuild the UI smoke scheme with development signing before native
runs; stage the authorized RAW copies and re-sign/strictly verify the DEBUG app
after every rebuild. Set `TEST_RUNNER_AAGEDAL_NATIVE_RAW_RECOVERY=1` and disable
parallel testing. Native selectors are under
`AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests`:

- `testOrdinarySyncPublicationRetainsRecoveryAfterInterruption`
- `testManagedOrdinarySyncPublicationRetainsRecoveryAfterInterruption`
- `testOrdinaryCameraRawSyncRetainsPartialPairAfterInterruption`
- `testManagedOrdinaryCameraRawSyncRetainsPartialPairAfterInterruption`
- `testOrdinaryCanonRawSyncRetainsPartialPairAfterInterruption`
- `testManagedOrdinaryCanonRawSyncRetainsPartialPairAfterInterruption`

Hosted regressions are in `LocalOrdinaryPublicationTests` and
`SyncSchedulerTests`, with existing matching/local/activated suites and the
complete application target as integration checks. Missing opted-in camera media
fails; unrequested camera checks skip. Never stage private media in Release.

## Limits and remaining gates

This slice protects ordinary local destination publication and collision-safe
local grouped imports. Managed processed-copy handoff still uses its separate
publication path; interruption during that handoff remains open. Native evidence
covers fresh local-to-local left-to-right imports at one boundary, not ordinary
replacement interruption, all earlier boundaries, remote/native transfers,
reverse direction, metadata-disabled/custom-root acceptance or multi-image
selected-clip partial publication. Those need further checks.

Normal local groups now copy recovery snapshots and verify bytes; their enriched
throughput impact has not been measured against release budgets.

No filesystem isolation from already-open writers or power-loss durability is
promised. Original camera sidecars, production recovery UX, macOS 14, VoiceOver,
controlled enriched performance, companion native interchange and complete signed
Release acceptance remain open. The historical candidate stays IMPLEMENTING;
M5 and readiness for the user's final acceptance remain open.
