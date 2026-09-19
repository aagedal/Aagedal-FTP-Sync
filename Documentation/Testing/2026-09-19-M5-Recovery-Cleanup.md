# M5 recovery cleanup failures — 2026-09-19

Source: clean `8601fea` base plus the source, tests and documentation committed
with this report on `codex/version-3-0-plan`. Host: arm64 macOS 27.0 (`26A428`),
Xcode 27.0. App identity remains 2.9.2 (37). No private results JSON was present;
the earlier development candidate remains unchanged.

## Change

Byte-matched publication previously discarded recovery-directory removal errors
in a defer. Successful publication could therefore report success while leaving a
recovery folder that prevented the next run. Explicit cleanup now reports the path
and whether publication completed or originals were preserved/restored after a
failure. Cleanup after rollback includes both the original and cleanup errors.
Committed replacements are not rolled back after original backups have been deleted.
Existing retained-conflict and original-backup cleanup behavior remains intact.

An injected removal failure exercises both paths. Regression checks verify published
bytes survive successful publication, original bytes survive cancelled publication,
retained manifests remain inspectable, and a newly opened session rejects further
processing. Removing the resolved disposable recovery folder restores admission
without changing the published output.

## Verification

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/LocalSyncIntegrationTests CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

All checks exit 0. XCTest executes 99 tests: 98 pass, one opt-in large-folder
benchmark is skipped, zero fail. This includes 29 activated integration, 16
publication (one skipped), and 54 local-sync tests. Initial sandboxed Xcode access
failed on compiler/package caches; approved Xcode access completed the tests.

Log: `build/v3-recovery-cleanup.log`.
Result: `build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_21-57-20-+0200.xcresult`.
App: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.

## Remaining acceptance

These are injected filesystem failures using disposable bytes, not native UI,
actual process termination, power-loss durability or camera RAW evidence. Other
project tasks were active on the shared desktop; this slice used non-UI checks.
Native recovery/reconciliation, full-batch overhead, supported-OS validation,
real-model calibration and final candidate/release gates remain open. No milestone
or checklist acceptance gate is closed by this report.
