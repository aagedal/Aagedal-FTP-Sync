# Deterministic editor launch and native recovery — 2026-09-20

Source: `38fca95` plus the two Swift-file changes committed with this report,
on `codex/version-3-0-plan`. Host: arm64, macOS 27.0 (`26A428`), Xcode 27.0
(`27A266a`). Current development identity is 3.0.0 (38), introduced at
`866e44d`; the older tracked development candidate and private checklist history
remain unchanged. No local results JSON was present at the start of this run.

## Finding and change

Editor tests relied on macOS restoring the Jobs scene. Their existing on-appear
helper could only raise an already-created window. The current-source baseline
passed the shared recovery test in 124.616 seconds, but needed the relaunch and
status-menu fallback for all three openings. This run did not reproduce a
production menu-opening failure; it confirmed the test's dependence on restoration.

Isolated editor launches now explicitly request Jobs from the live menu-label
scene once a test store is admitted. Both the existing UI-testing flag and a new
explicit open-Jobs flag are required. Ordinary production launches and version-3
startup/migration tests do not set this option. Tests now assert the requested
window directly instead of silently terminating and relaunching the process.

A separate regression closes and reopens Jobs twice through its actual status-menu
button, preserving coverage of the normal menu path. It passes, as do the two
native recovery cases that previously had inconsistent combined results.

## Verification

All Xcode commands use:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency
```

The baseline adds
`-only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testRetainedMetadataRecoveryExplainsBlockedReprocessingAndAllowsRetry`.
It passes 1/1, exit 0, before the Swift changes. Log:
`build/v3-jobs-launch-baseline.log`. Result:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.20_22-38-42-+0200.xcresult`.
The initial restricted attempt failed on Xcode/SwiftPM cache access; the approved
cache/test-runner invocation completed normally.

The changed-source command adds these three `-only-testing:` selections,
each prefixed with `AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/`:

- `testJobsWindowReopensFromStatusMenuAfterClosing`: passed, 44.256 seconds.
- `testProgrammingRecoveryReviewShowsFailureForAllAndClipScopesThenRetries`:
  passed, 34.890 seconds; full-batch and clip recovery errors appear in the sheet,
  cancellation works, and explicit fixture reconciliation admits a new scan.
- `testRetainedMetadataRecoveryExplainsBlockedReprocessingAndAllowsRetry`:
  passed, 38.720 seconds; repeated blocked reviews, cancellation, reconciliation,
  two subsequent launches and preserved original/reviewed bytes are verified.

Combined result: 3 tests, zero failures, exit 0. Log:
`build/v3-jobs-launch-focused-ui.log`. Result:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.20_22-41-38-+0200.xcresult`.
These are signed native XCTest observations with accessibility assertions and
attachments. Desktop inventory and the other active project's current work were
checked before testing; no concurrent desktop testing was observed.

`Scripts/check-security-baseline.sh`, `Scripts/check-release-identity.sh` and
`git diff --check` pass. The identity guard explicitly reports a development build,
not a shipping release. Xcode's unrelated generated string-catalog changes were
reviewed and restored; no strings were introduced by this change.

Built app: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.
Its app-code debug dylib SHA-256:
`4877195a1fb75c9c0cfefcdb477fb15d200c6f4198e4e08142cdc9d8f603eb2f`.

## Remaining gates

This closes the recorded focused shared-editor rerun gap on the current host.
It does not establish universal window-launch reliability or a full UI-suite pass.
The recovery fixtures use text bytes and an empty eligible-image batch; scoped
real-image publication, edited-output review, camera RAW/XMP, managed folders,
VoiceOver and macOS 14 remain open. Continue those native M5 workflows next.
No final-candidate checklist cases were marked passed, and 3.0 remains IMPLEMENTING.
