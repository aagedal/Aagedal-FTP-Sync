# M5 audit ordering and enriched reprocessing batch — 2026-09-19

Source: clean `2c144e1e9842136ad89bec621dd5b296ffb44345` plus the code,
tests and documentation committed with this report on `codex/version-3-0-plan`.
Host: arm64 macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`). App: 2.9.2 (37).
No private results file was present. The development candidate is unchanged.

## Correctness fix

Audit JSON uses whole-second ISO-8601 dates. Previously, equal timestamps were
ordered by UUID, which could select an earlier success instead of a later failure
and discard the later failure when trimming history. The regression deliberately
gives the success a larger UUID and checks both exact timestamp ties and outcomes
250 ms apart. Reopen, resave and bounded retention each fail before the fix: six
reproduced assertions, exit 65.

Persistence now preserves input order for equal dates through sorting and retention.
Both repository queries and AppStore reprocessing use the same latest-outcome
selector, which prefers the later row on a tie. Chronologically newer dates still
win regardless of row order. The serialized format and backup behavior are unchanged.
This preserves future ordering; chronology already lost in previously reordered
whole-second records cannot be reconstructed from those records.

## Enriched benchmark

The new opt-in test creates 25 decodable 4×4 JPEGs and 25 opaque synthetic CR3
primaries. Initial regular transfer writes date templates and establishes source
signatures and XMP companions. A changed job adds scheduled GPS, City/Country and
a caption combining a place variable with a frozen processing date. The geocoder
is deterministic and local, returning Oslo/Norway; no network or real face data
is involved.

Each folder runs read-only stale/incomplete preflight, real JPEG/XMP replacement,
audit repository append/reopen, and current-receipt repeat. Assertions verify:

- All 50 files are eligible and published without conflicts or failed outcomes.
- Preflight leaves all destination primaries and companions byte-identical.
- Published metadata has the expected resolved headline and city, with RAW XMP
  country checked too; source files and destination RAW bytes remain unchanged.
- All 50 complete receipts survive repository reopening.
- Repeating with reopened receipts skips all 50 as current and preserves outputs.

There are zero or 100,000 unrelated `.txt` files in the destination root. Timing
excludes fixture creation, initial transfer, assertions and cleanup. Publication
timing includes audit persistence; preflight runs first and warms files/provider
state. These are Debug-build observations on a shared host, not isolated cold/warm
release throughput measurements. No real geocoder latency, face inference, camera
RAW decoding, peak memory or cancellation budget is established here.

| Background files | Preflight | Publication + audit | Current-receipt repeat |
| --- | ---: | ---: | ---: |
| 0 | 1.122 s | 1.762 s | 0.417 s |
| 100,000 | 8.887 s | 12.424 s | 8.243 s |

One final-code batch per folder size. The earlier benchmark before the audit fix
observed 0.455/1.570/0.184 s without background files and 9.624/13.474/8.327 s
with 100,000. Shared-host variance and different code states prevent attributing
those timing differences to the ordering change. No performance gate is closed.

## Verification

```sh
# Before the fix: expected failing reproduction.
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/MetadataAuditTests/testSameSecondFailureStaysNewestAfterReopenResaveAndRetention \
  CODE_SIGNING_ALLOWED=NO
# Final shared selection and persistence implementation.
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests CODE_SIGNING_ALLOWED=NO
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_BENCHMARK=1 xcodebuild test \
  -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests/testLargeFolderEnrichedReprocessingBenchmark \
  CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

Complete non-UI suite: 1,218 executed, 1,193 passed, 25 opt-in skips, zero failures,
exit 0. Result: `build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_22-54-49-+0200.xcresult`.
The final opt-in benchmark passes separately (one test, zero skips/failures,
exit 0): `Test-AagedalFTPSync-2026.09.19_22-56-17-+0200.xcresult` in the same
result directory. The unsigned test app is
`build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.
Its executable SHA-256 is
`b2fd270394fda3a66a18cce49ffac40e977db1d7c19ddd4fe18b6d3e282defab`;
actual Debug application code is in `Contents/MacOS/Aagedal FTP Sync.debug.dylib`,
SHA-256 `2f3a7d3770de5167b790b053e1187a1a435750104a159923375ea15b657c8f58`.

Security/current-identity/diff checks pass. Xcode required approved compiler/package
cache access after the initial sandbox attempt failed to load dependency manifests.
Logs: `build/v3-audit-order-before.log`, `build/v3-audit-order-full.log`,
`build/v3-enriched-reprocess-final.log`. The first successful pre-fix benchmark is
retained separately in `build/v3-enriched-reprocess-benchmark.log`.

## Remaining work

Large-folder enumeration and repeated recovery checks still have a substantial
cost, including an unchanged receipt pass. Measure and improve these paths without
caching away fresh recovery checks. Repeat production provider/model workloads on
representative real images against the M0 budgets.

Other project tasks were active on the shared desktop; this slice used isolated
non-UI fixtures. Native recovery/reconciliation, real-face calibration, camera RAW,
supported-OS evidence, signed candidate checks and final human acceptance remain
open. No milestone or agent checklist case is marked passed by this report.
