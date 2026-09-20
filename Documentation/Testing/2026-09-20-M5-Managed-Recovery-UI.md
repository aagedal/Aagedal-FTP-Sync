# Managed-folder native recovery — 2026-09-20

Source: clean `1f35a45` plus the three Swift-file changes committed with this
report, on `codex/version-3-0-plan`. Host: arm64 macOS 27.0 (`26A428`),
Xcode 27.0 (`27A266a`). Development identity: 3.0.0 (38). The historical
candidate and private checklist lanes remain unchanged; no local results JSON
was present.

## Change and observations

The isolated native recovery fixture now supports the managed `Synced Files`
destination, selected by an explicit UI-test-only environment option. It uses
real folder bookmarks, disabled jobs, a version-3 fixture store, retained original
and output snapshots, and the existing explicit reconciliation launch step.
Ordinary app launches do not enable these fixtures.

Both shared Saved Metadata Processing and Metadata Programming now have ordinary
and managed-folder native regressions. All four pass together. They observe the
recovery error, cancel the failed review, reconcile the disposable fixture, relaunch,
and observe an admitted preflight. Programming covers full-batch and clip-scoped
review; the shared editor repeats blocked review and verifies retained original
and reviewed visible bytes across two post-reconciliation launches. The path guard
requires the exact isolated session and expected destination before inspecting it.

The underlying fixture regression also verifies real engine rejection, manifest
paths, no reseeding after reconciliation, persisted job edits, preserved bytes,
and fail-closed handling of damaged fixture storage in both destination modes.
The first run caught a test setup mistake: its direct session inspected `Processed
Files` instead of the reprocessing input `Synced Files`. Correcting the assertion's
session selection produced a passing rerun; this was not a production defect.

## Verification

Commands run from the repository root:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testManagedMetadataRecoveryExplainsBlockedReprocessingAndAllowsRetry \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testManagedProgrammingRecoveryReviewShowsFailureForAllAndClipScopesThenRetries \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testRetainedMetadataRecoveryExplainsBlockedReprocessingAndAllowsRetry \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testProgrammingRecoveryReviewShowsFailureForAllAndClipScopesThenRetries
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

- Focused non-UI: 26 executed, 22 passed, four opt-in skips, zero failures, exit 0.
- Signed native: four passed, zero failures, exit 0. Managed shared editor:
  37.669 s; managed programming: 33.892 s; ordinary programming: 34.333 s;
  ordinary shared editor: 38.736 s.
- Security/current-development-identity and diff checks pass.

The initial restricted command could not access Xcode/SwiftPM caches; the approved
invocations completed. Desktop inventory and the other active tasks were inspected
before the native run; no other active UI test was observed. A separate computer-use
attachment timed out and supplies no additional visual evidence. Native evidence
comes from the signed XCTest accessibility assertions and attachments.

Logs: `build/v3-managed-recovery-unit.log` (initial fixture failure),
`build/v3-managed-recovery-unit-final.log`, and `build/v3-managed-recovery-ui.log`.
Result bundles under `build/v3-preview-consistency/Logs/Test/`:

- `Test-AagedalFTPSync-2026.09.20_23-15-52-+0200.xcresult`
- `Test-AagedalFTPSyncUISmokeTests-2026.09.20_23-16-14-+0200.xcresult`

App: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.
App-code debug dylib SHA-256:
`390e129d37d7919f2e9ac1da43ebe6be6a638290d9d016663bb65298c31e2b84`.

## Remaining scope

These are text-byte recovery fixtures followed by an empty eligible-image batch.
They prove recovery admission and relaunch in managed folders, not real-image
publication or camera RAW/XMP reconciliation. Continue scoped image/conflict
recovery, stop controls, ordinary-sync interruption, VoiceOver and macOS 14 checks.
No complete UI-suite, release-candidate or milestone acceptance is claimed.
