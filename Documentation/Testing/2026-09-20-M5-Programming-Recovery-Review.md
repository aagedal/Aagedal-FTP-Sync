# Metadata Programming recovery review — 2026-09-20

Source: `13d78f1` plus the changes committed with this report, on
`codex/version-3-0-plan`. Host: arm64, macOS 27.0 (`26A428`), Xcode 27.0
(`27A266a`). Development identity remains 2.9.2 (37). Candidate identity and
private user checklist results are unchanged.

## Finding and change

The live review sheet fixed the native dialog's frozen content, but Metadata
Programming still constructed its message from only an optional successful
preflight. A failed scan had no result, so its sheet continued to say that the
destination was being checked. The recovery error was visible only in the
underlying editor, with no actionable error inside the modal sheet.

The coordinator now reads the current failure when presenting the review and
shows its recovery path and reconciliation instructions inside the sheet.
Failed preflight still offers no processing action and produces no competing
global alert. Cancel and a new scan clear the old failure normally.

A real local-folder regression covers all-file, photographer and clip scopes.
Each retains original bytes, rejects confirmation after recovery admission
fails, cancels the review, moves the disposable transaction outside the output
folder, and verifies a fresh successful empty-folder preflight. This checks
actual engine and AppStore behavior rather than injecting a presentation state.

## Verification

All Xcode commands use `-project 'Aagedal FTP Sync.xcodeproj'`,
`-destination 'platform=macOS'` and `-derivedDataPath build/v3-preview-consistency`.
The initial sandboxed build could not write Xcode/SwiftPM caches; the approved
cache-access run completed successfully.

`xcodebuild test -scheme AagedalFTPSync
-only-testing:AagedalFTPSyncTests/MetadataProgrammingCoordinatorTests`:
46 tests passed, zero failures, exit 0. Log:
`build/v3-programming-recovery-focused.log`. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.20_00-09-56-+0200.xcresult`.

The new signed native regression
`testProgrammingRecoveryReviewShowsFailureForAllAndClipScopesThenRetries`
passes the full-batch and clip context-menu actions, observes the recovery
instructions in the sheet, checks the absence of processing actions, cancels
both reviews, and relaunches with explicit test-only reconciliation. The new
scan shows zero eligible files and keeps the processing action disabled.

The native command uses `-scheme AagedalFTPSyncUISmokeTests`, selecting
`AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testProgrammingRecoveryReviewShowsFailureForAllAndClipScopesThenRetries`
and `AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testRetainedMetadataRecoveryExplainsBlockedReprocessingAndAllowsRetry`.
In this combined run the new test passed in 92.653 seconds. The existing shared
editor test failed before reaching recovery: its Jobs-window fallback briefly
found the menu-bar control, then could no longer locate it to click. Thus the
combined command exited 65; it is not a two-test pass. Log:
`build/v3-programming-recovery-ui.log`. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.20_00-10-31-+0200.xcresult`.
The native observations come from signed XCTest accessibility queries and
attachments. Computer-use inventory was checked before this run; no concurrent
desktop test was reported by the other active project tasks.

A separate unchanged-source retry selected only the existing shared-editor test.
It reached the initial recovery reviews, but failed to reopen the Jobs window
after relaunch; the subsequent editor/reprocess queries therefore also failed.
One test, three assertions, exit 65. Log:
`build/v3-programming-recovery-shared-ui-retry.log`; result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.20_00-13-21-+0200.xcresult`.
This run does not renew the earlier shared-editor acceptance evidence. Investigate
the native menu-bar/Jobs-window launch reliability before the full signed suite.

`Scripts/check-security-baseline.sh`, `Scripts/check-release-identity.sh` and
`git diff --check` pass. The Debug app is
`build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`;
its app-code debug dylib SHA-256 is
`2486f93d9818e215b46a9999cc6e12850d1fa396f2b57a5926aa59f284bb4652`.

## Remaining scope

The native fixture uses retained text bytes and an empty eligible-image batch.
It proves failure presentation and admission retry, not scoped image selection,
edited-output publication, camera RAW/XMP integrity, managed output folders,
real-model calibration, VoiceOver or macOS 14 compatibility. Those gates and
the full candidate-source suites remain open. Version 3.0 is IMPLEMENTING.
