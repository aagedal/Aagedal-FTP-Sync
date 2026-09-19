# Live metadata preflight review — 2026-09-19

Source: `774175d` plus the changes committed with this report, on
`codex/version-3-0-plan`. Host: arm64, macOS 27.0 (`26A428`), Xcode 27.
Development identity remains 2.9.2 (37); the tracked release candidate and private
user checklist results are unchanged.

## Findings and changes

The native recovery fixture had two defects: it enabled geocoding without a
frozen processing time zone, and it attempted to save that v3 policy through a
legacy job repository. The former produced `invalidSource` during preflight;
the latter silently omitted the seeded job. The fixture now selects `Etc/UTC`,
initializes an isolated v3 job envelope, preserves existing stores on relaunch,
and reports persistence failures instead of silently continuing.

Once the job was available, signed XCTest captured a native review dialog still
showing “Checking Files…” while the editor behind it already showed the recovery
failure. The native confirmation dialog did not refresh its content after the
asynchronous preflight changed state. Both Saved Metadata Processing and Metadata
Programming now use the same SwiftUI review sheet, with live message/actions and
Escape cancellation. Existing admission, conflict approval, cancellation and
publication rules remain in place. Preflight failures no longer also raise a global
alert: native attachments showed that duplicate alert blocking the review sheet.
Actual reprocessing failures still raise their existing alert; an integration
regression explicitly verifies this distinction.

The recovery UI regression now scopes queries to the sheet and waits for its
presentation/dismissal. It checks two blocked attempts, then rescues the retained
original outside the transaction, keeps an edited visible output, and retries
across reconciliation and another relaunch. Filesystem reconciliation is an
explicit test-only launch option executed inside the fixture app sandbox; the UI
runner cannot write into that container. It rescues the original and moves the
complete remaining transaction outside the destination, preserving snapshots.
This is test setup, not an automatic recovery feature. The test validates the
launch UUID and fixed fixture paths before requesting reconciliation. The non-UI regression exercises
actual engine preflight, v3 persistence/reopening, preserved bytes and refusal to
overwrite a damaged existing fixture store.

## Verification

All Xcode commands use `-project 'Aagedal FTP Sync.xcodeproj'`,
`-destination 'platform=macOS'` and `-derivedDataPath build/v3-preview-consistency`.
Xcode required approved cache access. Computer-use attachment timed out; native
observations below come from signed XCTest and its accessibility attachments.

The pre-fix UI run failed before finding the seeded job. After correcting fixture
storage, the run reached the actual frozen dialog. Evidence:
`build/v3-native-recovery-v3-ui.log`, result bundle
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.19_23-39-05-+0200.xcresult`.
Exported accessibility attachments are in `build/v3-native-recovery-attachments/`;
the final hierarchy records the stale checking dialog and background failure.

Final signed native command: `xcodebuild test -scheme AagedalFTPSyncUISmokeTests`
with `-only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testRetainedMetadataRecoveryExplainsBlockedReprocessingAndAllowsRetry`.
One test passed, zero failures, exit 0. Log:
`build/v3-native-recovery-complete-ui.log`; result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.19_23-47-53-+0200.xcresult`.
The ordinary `testCreatesJobFromDraft` also passed in the preceding run; that
run's recovery case failed on the duplicate alert before the final fixes.

The tested Debug app is
`build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.
The app-code debug dylib SHA-256 after the successful signed UI run is
`0cdb361d8975ec8b38d6e0376fb15d713245773f3a42269028a51a8b9067603b`.
`Scripts/check-security-baseline.sh`, `Scripts/check-release-identity.sh` and
`git diff --check` pass. This is development evidence, not a release candidate.

Focused signed regression command: `xcodebuild test -scheme AagedalFTPSync`
with `-only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests`,
`-only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests` and
`-only-testing:AagedalFTPSyncTests/MetadataProgrammingCoordinatorTests`.
101 executed, 96 passed, five opt-in skips, zero failures, exit 0.
Log: `build/v3-native-recovery-focused.log`. The new reconciliation-launch test
also verifies preserved snapshots and idempotence after a later review edit.
The full non-UI and full native suites were not repeated for this focused change.

## Scope still open

This fixture uses text bytes and an empty eligible-image batch after recovery.
It does not establish camera RAW/XMP publication, real-model behavior, managed
folder recovery, macOS 14 support, or release readiness. Metadata Programming uses
the same sheet but needs its own native scope/conflict workflow observations.
Version 3.0 remains IMPLEMENTING.
