# M5 reset recovery protection — 2026-09-19

Development source: clean base `d3ae0c3` plus the implementation, regression and
records committed with this report on `codex/version-3-0-plan`. Host: arm64
macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`). Identity remains 2.9.2 (37).
No private results JSON was present; the earlier development candidate is unchanged.

## Change

Reset Job's managed-folder path bypassed recovery checks and included hidden
reprocessing transaction backups and failed-reset recovery trees in its deletion
plan. Ordinary destinations rejected failed-reset trees but admitted reprocessing
recovery, allowing ownership history to be cleared while retained originals remained.

Both reset preview and execution now reject either recovery-tree type before
planning deletion or clearing history. The error identifies the retained folder.
Resolving the recovery explicitly allows a subsequent reset. This guard handles
existing recovery state; it does not provide filesystem isolation from other processes
creating new recovery state concurrently with a reset.

## Verification

The new regression failed on the original code (exit 65), reproducing ordinary
reset preview accepting unresolved reprocessing recovery. With the fix, all 62
local-sync and matching-publication tests pass, zero failures or skips (exit 0).
The regression covers both folder modes and recovery types, preview and execution,
byte preservation, retained manifest ownership, and successful reset after recovery
is removed. Fixtures are disposable synthetic files; no user data was reset.

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

Security, current-identity and whitespace guards pass. Xcode required the approved
cache-access retry after the sandboxed attempt failed to load package manifests.
Logs: `build/v3-reset-recovery-before.log`, `build/v3-reset-recovery.log`.
Result: `build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_20-57-27-+0200.xcresult`.
Test app: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.

## Remaining acceptance

Other project tasks were active; this pass used isolated non-UI fixtures. Observe
the native reset error and recovery/retry flow next. Real-face calibration, camera
RAW, supported-OS execution and signed candidate validation remain open. No checklist
result or milestone was marked complete and no distribution action was performed.
