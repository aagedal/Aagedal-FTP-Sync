# M5 recovery scan performance — 2026-09-19

Source: clean `b8ddc3eff1f710a61c615f82a4d1a735bd710b59` base, plus the source,
tests and records committed with this report on `codex/version-3-0-plan`.
Host: arm64 macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`). App remains 2.9.2 (37).
No private results JSON was present; the earlier development candidate is unchanged.

## Change

Recovery admission, snapshot validation and byte-matched publication previously
materialized every root child name before testing for recovery. They now use a
fresh POSIX directory stream, check cancellation between entries, stop at the
first recovery name and close the stream on success, failure or cancellation.
No full name array or cross-call cache is retained. Read/open errors fail admission;
hidden regular files and dangling symbolic links with recovery names still block.
This preserves the existing name-based, manifest-independent recovery boundary.

## Verification and measurement

The focused selection passes 96 tests, zero failures, with the optional benchmark
initially skipped: 29 activated integration, 13 publication and 54 local-sync tests.
The separate opt-in benchmark then passes with zero skips/failures. New regressions
cover hidden recovery files, Unicode names, dangling reset links, disappearance of
the root, cancelled admission and unchanged destination bytes. Existing regressions
continue to cover recovery appearing after admission and publication retry.

The benchmark creates and removes 100,000 disposable empty image-named files. It
alternates the previous Foundation scan and the production streaming scan 20 times
in the Debug test app, then adds recovery and verifies fresh detection. These are
warm local APFS directory scans, not cold storage or enriched-image throughput.
The previous-path timing includes its no-match assertion and autorelease-pool drain.

| Scan | Median | p95 (nearest rank) | Maximum |
| --- | ---: | ---: | ---: |
| Previous name array | 191.13 ms | 202.47 ms | 203.93 ms |
| Streaming names | 39.28 ms | 40.54 ms | 40.83 ms |

Median speedup is 4.87×. Bounded name retention follows from implementation;
process memory and in-flight cancellation latency were not measured here.

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  -only-testing:AagedalFTPSyncTests/LocalSyncIntegrationTests CODE_SIGNING_ALLOWED=NO
TEST_RUNNER_AAGEDAL_RECOVERY_SCAN_BENCHMARK=1 xcodebuild test \
  -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests/testLargeFolderRecoveryScanBenchmark \
  CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

All final commands exit 0. The sandbox initially denied compiler/package cache
writes; approved Xcode access resolved that. A plain environment flag did not reach
the XCTest app; the `TEST_RUNNER_` prefix enabled the separate benchmark correctly.
Logs: `build/v3-recovery-scan.log` and `build/v3-recovery-scan-benchmark.log`.
Focused result: `build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_21-51-03-+0200.xcresult`.
Benchmark result: `build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_21-51-55-+0200.xcresult`.
App: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.

## Remaining acceptance

Each boundary still scans all root children when recovery is absent. Total overhead
can therefore grow with both root size and processed-image count; these timings do
not establish a full-batch budget pass. Directory streams provide no cross-process
filesystem isolation. In-flight cancellation latency, actual process interruption,
native recovery/reconciliation, camera RAW, real-face calibration and supported-OS
verification remain open. Other project tasks were active on the shared desktop;
this run used non-UI disposable fixtures. No checklist or milestone gate is closed.
