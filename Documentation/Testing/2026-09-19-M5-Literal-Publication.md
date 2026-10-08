# M5 literal-template publication safety — 2026-09-19

Development source: clean base `b07f4e6` plus the source, tests and documentation
committed with this report on `codex/version-3-0-plan`. Host: arm64 macOS 27.0
(`26A428`), Xcode 27.0 (`27A266a`). App identity remains 2.9.2 (37).
No private results JSON was present. The earlier development candidate is unchanged.

## Change

Literal-template reprocessing previously checked its input snapshot but then used
ordinary file replacement, allowing a later destination edit to be overwritten.
All local reprocessing now freezes originals and publishes through the existing
byte-matched transaction. Publication failures produce per-file failed outcomes,
so remaining files can continue. Template activation no longer determines edit
protection. Existing transaction recovery limitations still apply to external
writers holding open file descriptors.

## Verification

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  -only-testing:AagedalFTPSyncTests/MetadataProgrammingCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

Exit 0: 80 tests, zero failures. Security, current-identity and whitespace checks
pass. A disposable JPEG regression injects a destination edit after the transaction
holds the original; the edit survives and the result reports one failed file and
zero applied files. A separate literal-template RAW regression covers new and
existing companions, preserving the RAW bytes, inode and timestamp plus an unrelated
existing XMP caption. RAW bytes are synthetic, with no camera-RAW claim.

The initial sandboxed test attempt could not access compiler caches; the approved
retry passed. Final log: `build/v3-literal-publication.log`. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_20-45-54-+0200.xcresult`.

## Remaining acceptance

Native editor conflict/retry observation, real-face calibration, actual camera RAW,
supported-OS execution and signed candidate verification remain open. Concurrent
product work was active at intake; this run used isolated non-UI fixtures. No manual
checklist case or milestone was marked complete. Next verify native conflict and
retry behavior for literal and activated jobs alongside the existing stop controls.
