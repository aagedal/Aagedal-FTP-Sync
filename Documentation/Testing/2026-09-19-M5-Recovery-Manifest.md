# M5 reprocessing recovery manifest — 2026-09-19

Development source: clean base `7efe7d3` plus the implementation, tests and records
committed with this report on `codex/version-3-0-plan`. Host: arm64 macOS 27.0
(`26A428`), Xcode 27.0 (`27A266a`). App identity remains 2.9.2 (37).
No private results JSON was present; the earlier candidate identity is unchanged.

## Change

Retained reprocessing transactions previously contained numbered backups without
their original relative paths. Publication now atomically writes `recovery.json`
schema 1 before moving any original. It maps each original, inspected snapshot,
staged output and possible rollback output to the intended relative path. RAW
guard-only originals are explicitly distinguished from replaced files. Absolute
temporary input paths are not serialized.

The manifest is immutable and deliberately does not assert transaction completion.
Recovery requires comparing present files and preserving concurrent edits. The
[recovery guide](../Metadata-Reprocessing-Recovery.md) documents this distinction,
older manifest-free folders and reset retry. Successful publication and successful
rollback remove the manifest with the transaction directory.

## Verification

All 64 selected tests pass (10 matching-publication and 54 local-sync integration),
zero failures or skips, exit 0. New disposable synthetic-file regressions prove:

- A readable manifest exists before the first original moves; cancellation at
  that boundary leaves original bytes intact and removes temporary state.
- A nested Unicode RAW/XMP pair with a concurrently edited published sidecar
  retains the old sidecar and its correct destination mapping. RAW bytes and the
  concurrent edit survive, and recovery files stay excluded from normal listings.

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/LocalSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

All guards pass. Xcode needed an approved compiler/package-cache access retry
after sandbox manifest resolution failed. Log: `build/v3-recovery-manifest.log`.
Result: `build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_21-02-09-+0200.xcresult`.
Test app: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.

## Remaining acceptance

Other project tasks were active on the shared desktop, so this pass used isolated
non-UI fixtures. Native recovery/retry and actual process termination remain
unverified. Atomic manifest replacement is not a power-loss durability guarantee.
Real-face calibration, camera RAW, supported-OS and signed candidate gates remain
open. No milestone or checklist acceptance was marked complete.
