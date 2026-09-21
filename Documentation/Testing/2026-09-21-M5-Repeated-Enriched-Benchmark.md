# Repeated enriched reprocessing measurements — 2026-09-21

Source: clean `9e65b7c0fe4f9bf2b84e4b4a695a8062b4d5439a`, plus the test and
records committed with this report, on `codex/version-3-0-plan`. Production code
is unchanged. Host: Apple M5 Pro, 18 cores, 64 GB; macOS 27.0 (`26A428`),
Xcode 27.0 (`27A266a`). Development identity: 3.0.0 (38).
No private results JSON was present; historical candidate and checklist lanes
remain unchanged. Another project task was active; the desktop was not used.

## Harness and correctness

The existing opt-in enriched benchmark now accepts
`AAGEDAL_ENRICHED_REPROCESS_SAMPLES` (1–20, default 1). It reuses each disposable
background directory and its durable audit history. Every sample changes the
requested headline, so every publication must perform new metadata writes rather
than reuse a current receipt. Each sample then checks the unchanged repeat.

Five samples each with zero and 100,000 background files pass. Each processes
25 generated, decodable JPEGs and 25 opaque synthetic RAW files with valid XMP.
Across ten samples, all 500 publications and 500 current-receipt skips pass:
preflight changes no bytes; published Headline/City and RAW-sidecar Country are
correct; source images and RAW primaries stay intact; reopening the audit retains
all 50 complete receipts; and each following repeat leaves every output unchanged.
The injected geocoder is deterministic. Each sample creates a fresh engine/service;
these are warm filesystem measurements, not cold/warm production-provider tests.

## Measurements

Seconds, five samples per background size. Setup, fixture cleanup and explicit
integrity assertions are outside the reported intervals. Publication includes
appending the metadata report to the audit. Ranges show minimum–maximum; five
samples are insufficient for a robust tail-latency claim.

| Background files | Phase | Median | Range |
| ---: | --- | ---: | ---: |
| 0 | Preflight | 0.492 | 0.413–1.150 |
| 0 | Publication + audit | 2.699 | 0.725–3.346 |
| 0 | Current-receipt repeat | 0.216 | 0.210–0.638 |
| 100,000 | Preflight | 4.788 | 4.126–4.903 |
| 100,000 | Publication + audit | 7.248 | 6.883–7.463 |
| 100,000 | Current-receipt repeat | 3.858 | 3.785–4.104 |

A separate clean-source baseline passes both opt-in benchmarks. Its 20 alternating
100,000-file recovery scans measure streaming median 36.22 ms, nearest-rank p95
38.42 ms and maximum 49.10 ms; the older Foundation array comparison measures
188.48 ms median. The baseline full batch measures 4.439 s preflight, 7.764 s
publication plus audit and 4.117 s current-receipt repeat with background files.

Code inspection finds 51 fresh root recovery scans for a 50-image preflight or
current-receipt pass and 101 for publication. Multiplying by the separate scan
median suggests roughly 1.85/3.66 seconds of scan work. This is an estimate, not
instrumented phase attribution. Remaining enumeration/processing cost warrants
profiling. Fresh scans must continue to catch recovery appearing during suspended
resolution; no result caching or admission weakening was introduced.

## Reproduction and validation

```sh
TEST_RUNNER_AAGEDAL_RECOVERY_SCAN_BENCHMARK=1 \
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_BENCHMARK=1 \
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests/testLargeFolderRecoveryScanBenchmark \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests/testLargeFolderEnrichedReprocessingBenchmark \
  CODE_SIGNING_ALLOWED=NO

TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_BENCHMARK=1 \
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_SAMPLES=5 \
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

Baseline: two tests, zero skips/failures, exit 0. Extended harness and surrounding
integration/publication selection: 60 executed, 56 passed, four other opt-in cases
skipped, zero failures, exit 0. Security, development-identity and diff checks pass.
The restricted first build could not write compiler caches; approved Xcode access
resolved this. An initial unprefixed environment invocation skipped both benchmarks;
only the subsequent `TEST_RUNNER_` invocations supply measurement evidence.

Logs: `build/v3-recovery-cost-baseline.log` and
`build/v3-reprocessing-five-samples.log`. Result bundles under
`build/v3-preview-consistency/Logs/Test/`:

- `Test-AagedalFTPSync-2026.09.21_12-07-06-+0200.xcresult`
- `Test-AagedalFTPSync-2026.09.21_12-08-50-+0200.xcresult`

Unsigned app: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.
App-code debug dylib SHA-256:
`39b3d591207fb7c8787744f40d231911ee87cf392a6ebbda62a4345d8a633b16`.

## Remaining acceptance

The no-background timing variance and active shared host preclude a controlled
release-budget claim. This run adds repeatable measurement and verifies repeated
settings changes; it does not establish a production speedup. Next, profile the
remaining enumeration and per-image scans while preserving fresh recovery guards,
and run controlled production geocoder/model workloads. Native image recovery,
camera RAW, real-face calibration, supported-OS evidence and final candidate
validation remain open. No milestone or checklist gate is closed.
