# M5 reprocessing stop controls — 2026-09-19

Development source: clean base `2b08794` plus the code, tests and documentation
committed with this report, on `codex/version-3-0-plan`. Host: arm64 macOS 27.0
(`26A428`), Xcode 27.0 (`27A266a`). Version remains 2.9.2 (37). No local human
acceptance results JSON was present. The older development candidate is unchanged.

## Changes

Metadata Programming and Saved metadata processing now expose Stop Reprocessing
while a write batch is queued or running. The store registers the operation before
its task starts, presents a stopping state, and keeps admission blocked until the
task and concurrency lease drain. A finished stop reports that already completed
files remain updated. Dismissing a preflight still only cancels that preflight;
it cannot accidentally stop an approved write batch.

The engine carries completed per-file audit receipts out of a cancelled batch and
the store persists them. Cancellation checks run at entry, between images, after
preparation and before publication; cancellation during provenance hashing is
propagated rather than recorded as an ordinary metadata failure. A stopped
operation is distinct from an error and does not promise batch rollback.

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

Final exit 0: 68 tests passed, zero failures or skips. The new queued-operation
test holds an unrelated concurrency lease, stops the pending write batch, verifies
busy admission until drainage and proves a new real empty-folder preflight succeeds.
It also checks that Stop leaves a completed preflight untouched.

The two-image integration test uses generated decodable JPEGs and activated
headline metadata. It stops before the second image, verifies the first image's
completed receipt/fingerprint survives cancellation, and compares the second
image byte-for-byte with its original destination copy. Existing receipt,
source/output conflict, preview and review regressions also pass.

The first sandboxed attempt could not access compiler/SwiftPM caches. The approved
retry and the final regression run both passed. Final log:
`build/v3-reprocess-stop.log`. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_19-56-32-+0200.xcresult`.
Security baseline, current release identity and diff whitespace checks pass.

## Remaining acceptance

Other project tasks were active on the shared desktop; this pass used isolated
non-UI tests. Native button placement, keyboard/VoiceOver behavior, mid-inference
cancellation latency, camera RAW, supported-OS and signed-candidate checks remain
open. These tests do not demonstrate production real-face calibration or full M5
acceptance. No milestone or checklist case was marked complete.
