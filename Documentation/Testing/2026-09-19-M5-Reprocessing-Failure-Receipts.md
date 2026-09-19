# M5 reprocessing failure receipts — 2026-09-19

Development source: clean base `4245e1d` plus the code, tests and documentation
committed with this report on `codex/version-3-0-plan`. Host: arm64 macOS 27.0
(`26A428`), Xcode 27.0 (`27A266a`). Version remains 2.9.2 (37). No local human
acceptance results JSON was present. The older development candidate is unchanged.

## Change

A fatal error while staging a later destination image previously escaped the
reprocessing batch without the earlier files' audit report. Those files could
already contain published metadata, but their processing receipts were lost.
The engine now carries accumulated receipts with the original error, and the
store persists them before reporting the batch failure. It retains the original
localized error and does not hide an audit-persistence alert. Cancellation keeps
its existing separate outcome. Preflight never publishes these tentative receipts.

## Verification

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/MetadataProgrammingCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

Final exit 0: 69 tests passed, zero failures or skips. The new regression uses
generated JPEGs, real local endpoints and isolated version 3 job/audit stores.
After the first image completes, a test clock removes the second disposable
destination before export. The store drains its busy state and reports failure;
the first image contains the new headline, and its receipt identity/fingerprint
survive a reload from disk. Repeating the fault during preflight leaves the first
image byte-for-byte unchanged and the durable audit empty.

The sandboxed build initially could not access compiler/SwiftPM caches; the
approved run could. Initial regression fixture runs exposed required v3 envelope
initialization and timestamp precision differences on persistence; these were
corrected before the final passing run. Final log:
`build/v3-reprocess-failure.log`. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_20-22-48-+0200.xcresult`.
Security baseline, current release identity and diff whitespace checks pass.

## Remaining acceptance

Other project tasks were active on the shared desktop; this pass used isolated
non-UI tests. Native failure presentation, Stop controls, real-model cancellation,
camera RAW, supported-OS execution and signed candidate verification remain open.
No milestone or checklist case was marked complete.
