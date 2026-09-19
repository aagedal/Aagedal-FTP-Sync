# M5 clip reprocessing scope — 2026-09-19

Development source: clean base `fa7fc10` plus the code, tests and documentation
committed with this report on `codex/version-3-0-plan`. Host: arm64 macOS 27.0
(`26A428`), Xcode 27.0 (`27A266a`). Version remains 2.9.2 (37). No local human
acceptance results JSON was present. The older development candidate is unchanged.

## Change

Clip-specific reprocessing previously checked output receipts before checking the
resolved clip assignment. An edited destination belonging to another clip with
the same photographer prefix could enter the selected clip's conflict review and
audit report. Selected conflicts also bypassed the scanned-count increment.

Clip membership now gates conflict handling and receipt collection. The scan
counts every selected image, including protected edited outputs. Other clips and
unassigned images do not enter the selected clip's review or audit results.

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

Exit 0: 70 tests passed with zero failures or skips. The new integration regression
uses four generated JPEGs and real disposable local endpoints: two images in the
selected clip, one in another clip for the same photographer, and one outside all
clips. It runs both all-file and stale/incomplete filters. Preflight reports two
scanned, one ready, and one selected conflict without changing either selected
image. Explicit approval changes only the two selected headlines, emits only their
receipts, and preserves the excluded destinations byte-for-byte.

The initial sandboxed build could not access compiler/SwiftPM caches; the approved
retry passed. Final log: `build/v3-reprocess-clip-scope.log`. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_20-26-46-+0200.xcresult`.
Security baseline, current release identity and whitespace checks pass.

## Remaining acceptance

Other project tasks were active; this pass used isolated non-UI fixtures. Native
clip selection/review, keyboard/VoiceOver behavior, real-model calibration,
camera RAW, supported-OS and signed candidate checks remain open. No milestone or
checklist case was marked complete.
