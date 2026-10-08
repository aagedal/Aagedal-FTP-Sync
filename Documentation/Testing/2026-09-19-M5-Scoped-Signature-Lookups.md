# M5 scoped signature lookups — 2026-09-19

Source: clean `38da8822bcaf712ed71dd5fbe9ac274dc21439fe` plus the changes
committed with this report on `codex/version-3-0-plan`.
Host: arm64 macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`). App: 2.9.2 (37).
No private results file was present. The development candidate remains unchanged.

## Changes

Reprocessing loads saved source signatures only for its filtered candidate
primaries and their existing companions. A 50-image batch containing 25 RAW
files with XMP companions now requests 75 paths even when the destination also
contains 100,000 unrelated text files. The complete destination listing still
participates in collision checks. Recovery admission and byte-matched publication
remain unchanged.

The SQLite path-limited lookup now drives its join from the requested-path table,
using CROSS JOIN to retain that loop order. Each requested path uses the complete
(job, endpoint, path) primary key. The previous ordinary join could scan the
job/endpoint's entire history before testing membership in the requested set.
No database schema or saved signature semantics change.

The RAW regression checks read-only preflight and no-write receipt bootstrap
with an XMP companion excluded by the photo filter. It verifies complete source
evidence, unchanged primary/sidecar bytes, inode and modification date. Its first
run failed because the fixture assumed legacy RAW transfers persisted the primary
signature; the corrected fixture explicitly supplies that ownership prerequisite
and uses the real transfer's saved companion. Repository regressions also cover
job/endpoint isolation, duplicate/missing requests, empty batches and subsequent
requests replacing the temporary path set.

## Measurements

The existing enriched benchmark uses 25 generated JPEGs, 25 opaque synthetic RAW
files, real metadata writes, deterministic geocoding and durable receipts. Each
row is one Debug sample on a shared host, not a release-budget determination.

| Background files | Code | Preflight | Publication + audit | Current-receipt repeat |
| --- | --- | ---: | ---: | ---: |
| 0 | Before | 0.971 s | 2.208 s | 0.361 s |
| 0 | After | 0.887 s | 2.080 s | 0.428 s |
| 100,000 | Before | 4.527 s | 8.151 s | 3.875 s |
| 100,000 | After | 4.252 s | 7.627 s | 3.769 s |

The large-folder sample improves modestly; the small-folder idle sample is slower.
Enumeration and fresh per-image recovery scans still dominate this workload.

The opt-in application repository test inserts one million records and repeats
three requested paths 20 times, asserting returned values each time. Median
lookup time is 0.000014 s; p95 is 0.000024041 s. This includes temporary-table
replacement, transaction handling and Swift result materialization.

A separate in-memory SQLite 3.53.4 query-only probe uses the same million-row
primary-key schema and exact before/after SELECT statements. EXPLAIN QUERY PLAN
confirms the old job/source scan and new requested-path scan plus full-key lookup.
Across 20 samples, median SELECT time is 0.035095 s before and 0.000002229 s after.
These query-only numbers exclude application/storage overhead and must not be
interpreted as end-to-end acceleration. Log: `build/v3-signature-query-probe.log`.

## Verification

```sh
# Clean-source baseline: selected only testLargeFolderEnrichedReprocessingBenchmark.
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_BENCHMARK=1 xcodebuild test \
  -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests/testLargeFolderEnrichedReprocessingBenchmark \
  CODE_SIGNING_ALLOWED=NO
TEST_RUNNER_RUN_SOURCE_SIGNATURE_SCALE_TESTS=1 xcodebuild test \
  -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/SourceSignatureRepositoryTests \
  -only-testing:AagedalFTPSyncTests/MetadataGeocodingSyncIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_BENCHMARK=1 xcodebuild test \
  -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

Focused final run: 59 executed, 58 passed, one enriched-benchmark opt-in skip,
zero failures, exit 0. The separate million-record scale test passes in this run.
Full final non-UI run: 1,224 executed, 1,200 passed, 24 opt-in skips,
zero failures, exit 0. This run includes the enriched benchmark; the million-row
lookup test passed separately above. Security, current-identity and diff checks
pass. Xcode required approved cache access after sandboxed package resolution failed.

Result bundles under `build/v3-preview-consistency/Logs/Test/`:

- Clean-source baseline: `Test-AagedalFTPSync-2026.09.19_23-20-28-+0200.xcresult`.
- Final focused: `Test-AagedalFTPSync-2026.09.19_23-24-47-+0200.xcresult`.
- Final full suite: `Test-AagedalFTPSync-2026.09.19_23-25-23-+0200.xcresult`.

Test app: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`
(unsigned). Executable SHA-256:
`b2fd270394fda3a66a18cce49ffac40e977db1d7c19ddd4fe18b6d3e282defab`.
Application-code `Contents/MacOS/Aagedal FTP Sync.debug.dylib` SHA-256:
`b568c026d1e40cde8715f8dfeed50b26ebd8b999395648835e512bcfc95c7516`.

Logs: `build/v3-signature-scope-before.log`, `build/v3-signature-indexed-tests.log`
and `build/v3-signature-full.log`. The intermediate scope-only run and initially
incorrect fixture are retained in `build/v3-signature-scope-after.log`.
Other projects have active tasks on the shared desktop. No native UI, production
provider/model, camera RAW or supported-OS acceptance is claimed here. No milestone
or agent checklist case is closed; version 3.0 remains IMPLEMENTING.
