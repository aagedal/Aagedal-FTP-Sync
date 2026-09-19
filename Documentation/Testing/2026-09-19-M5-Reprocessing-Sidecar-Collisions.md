# M5 reprocessing sidecar collisions — 2026-09-19

Development source: clean base `b2975c0` plus the implementation, regression and
records committed with this report on `codex/version-3-0-plan`. Host: arm64
macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`). Identity remains 2.9.2 (37).
No private results JSON was present. The earlier development candidate is unchanged.

## Change

Scheduled-only reprocessing bypassed the generated-sidecar collision guard. Mixed
processing also restricted that guard to independently enriched inputs. Reprocessing
now validates the entire candidate batch using the existing transfer path rules before
preparing or publishing any image. Two RAW primaries targeting the same companion
are rejected for both preflight and execution, whether that companion exists or not.
The existing conservative reservation rules apply before clip assignment resolution.

## Verification

The new regression failed before the fix (exit 65), demonstrating an existing
sidecar changed and an earlier JPEG rewritten rather than rejecting the batch.
After the fix, 81 focused tests passed with zero failures (exit 0). The regression
covers literal and activated schedules, absent and existing XMP, and both preflight
and execution. All input bytes, existing captions and sidecar absence are preserved.
Existing single-RAW tests continue to verify valid creation and replacement.
RAW bytes are synthetic; this is not camera-RAW or native UI acceptance evidence.

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

Security, current-identity and whitespace guards pass. The initial sandboxed test
attempt could not access compiler caches; the approved retry executed successfully.
Logs: `build/v3-reprocess-collision-before.log` and `build/v3-reprocess-collision.log`.
Result: `build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_20-51-08-+0200.xcresult`.
Test app: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.

## Remaining acceptance

Concurrent product tasks were active at intake; this slice used isolated non-UI
fixtures. Observe native collision reporting, destination conflict/retry and stop
controls next. Real-face calibration, actual camera RAW, supported-OS execution and
signed candidate validation remain open. No manual checklist or milestone was marked
complete, and no distribution action was performed.
