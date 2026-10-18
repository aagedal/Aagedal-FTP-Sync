# Current reprocessing and history profile — 2026-10-18

## Source and method

Branch `t3/stabilize-v3-ui`, base `d660514`, with the pending setup changes.
App/test source is unchanged from the
[current transport run](2026-10-18-Current-Source-Transport-Acceptance.md).
Its ignored code/test diff still has SHA-256
`4acaefe79aa92d2d10002030ccdcc28d6ff49b4045d3e02c8fce8dff23905d7c`.
No application or benchmark implementation changed during these measurements.

Host: arm64 MacBook Pro, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a),
development identity 3.0.0 (44). These are Debug measurements on the shared host
with warm filesystem caches, deterministic geocoding and generated fixtures.
They do not establish a release-budget pass or a speedup over historical runs.

## Enriched reprocessing

```sh
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_BENCHMARK=1 \
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_SAMPLES=3 \
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/continuation-tests \
  -disableAutomaticPackageResolution \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests/testLargeFolderEnrichedReprocessingBenchmark \
  CODE_SIGNING_ALLOWED=NO
```

One opt-in test passes, zero failures/skips, exit 0 (65.056 seconds including
fixture setup and teardown). Three samples at each background size verify 300
publications, 300 following current-receipt skips and 300 preflight decisions.
Each 50-image batch contains 25 generated JPEGs and 25 synthetic RAW/valid-XMP
pairs. Assertions retain source/output bytes, enriched metadata, receipts,
no-write preflight and unchanged no-op outputs.

Median seconds; each timing column is independently aggregated:

| Background files | Phase | Total | Listing | Recovery | Copy | Validate | Publish | Other |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | Preflight | 0.3382 | 0.0007 | 0.0061 | 0.0153 | 0.0153 | 0 | 0.3008 |
| 0 | Publication and audit | 0.5477 | 0.0007 | 0.0117 | 0.0158 | 0.0151 | 0.1842 | 0.3202 |
| 0 | Current-receipt repeat | 0.1950 | 0.0007 | 0.0058 | 0.0161 | 0.0154 | 0 | 0.1571 |
| 100,000 | Preflight | 3.6177 | 0.6439 | 1.9661 | 0.0150 | 0.0198 | 0 | 0.9754 |
| 100,000 | Publication and audit | 5.8102 | 0.6412 | 3.9198 | 0.0161 | 0.0202 | 0.2151 | 1.0044 |
| 100,000 | Current-receipt repeat | 3.5158 | 0.6530 | 1.9906 | 0.0161 | 0.0202 | 0 | 0.8410 |

Every phase performs one listing, 75 snapshot exports, 50 snapshot validations
and zero individual file lookups. Preflight/repeat perform 51 fresh recovery
checks; publication performs 101 checks and 50 grouped transactions.

Fresh recovery enumeration remains the main large-folder cost. Independent code
review found no evidence-backed low-risk optimization for the measured ordinary
filename workload. It already avoids Swift String allocation for those names.
The previous bulk-API experiment was slower. Retain fresh admission, hidden/link
detection, cancellation and error handling rather than weakening them for a
benchmark. No production performance change was made.

Log: `build/current-enriched-reprocessing-profile.log`.
Aggregated data: `build/current-enriched-reprocessing-summary.json`.
Result: `build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.18_17-58-52-+0200.xcresult`.

## Million-record source history

```sh
TEST_RUNNER_RUN_SOURCE_SIGNATURE_SCALE_TESTS=1 \
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/continuation-tests \
  -disableAutomaticPackageResolution \
  -only-testing:AagedalFTPSyncTests/SourceSignatureRepositoryTests/testOneMillionRecordIndexedStore \
  CODE_SIGNING_ALLOWED=NO
```

One opt-in test passes, zero failures/skips, exit 0 (2.605 seconds). The fixture
records one million paths in 10,000-item batches, then makes 20 indexed requests
for three paths spanning the history. Each request verifies the returned count
and the middle path's expected size. Reported warm lookup median is 14.25 µs,
p95 26.5 µs. This is a three-path lookup measurement, not full-history loading,
reopen durability, memory, cold-cache or end-to-end sync acceptance.

Log: `build/current-source-signature-scale.log`. Temporary database fixtures are
removed by the test; no user source history is opened.
Result: `build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.18_18-01-24-+0200.xcresult`.

## Remaining gates

Production geocoder/model workloads, camera RAW, controlled cold/warm conditions,
peak memory, cancellation latency, fresh ordinary/processed-handoff throughput
and release budgets still require measurement. Reprocessing does not measure the
new fresh processed-copy handoff. The initial fixture transfer is outside the
timed reprocessing phases.

The three setup native regressions remain pending the user's requested desktop
wait. PHP/MariaDB still needs an available Docker daemon. Supported-OS,
VoiceOver, real-model accuracy and final-candidate acceptance remain open.
M5 remains open and the historical candidate stays IMPLEMENTING.

After the unsigned runs, signed native build-for-testing was restored successfully
without executing UI tests (`build/profile-final-ui-ready.log`, exit 0).
