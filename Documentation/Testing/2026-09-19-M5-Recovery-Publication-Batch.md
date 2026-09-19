# M5 recovery publication batch — 2026-09-19

Source: clean `ff12b07d8ec694c1380f4fcc6aa7fddbe2da7a29` plus the source,
tests and report committed together on `codex/version-3-0-plan`.
Host: arm64 macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`). App remains 2.9.2 (37).
No private results file was present. The previous development candidate is unchanged.

## Implementation and coverage

Recovery scans now discard non-hidden directory entries before constructing a
Swift filename string. All recovery names start with an ASCII period; hidden
entries still use the complete existing predicate. Every entry retains its
cancellation check. No result cache, recovery bypass, or filesystem isolation
claim is introduced. Coverage includes unrelated hidden names, visible names
resembling recovery, Unicode filenames, hidden Unicode recovery, dangling reset
links, missing roots, cancellation and recovery created after admission.

The new opt-in batch benchmark exercises the actual snapshot-validation and
byte-matched publication methods. Each batch creates 50 nested synthetic RAW
primaries and publishes a new XMP companion for each, with one initial admission
plus two boundary scans per image (101 scans). It runs with zero and 100,000
unrelated root files. All original and output bytes are checked after publication;
no transaction remains. Introducing a recovery artifact after the batch blocks
both snapshot validation and another publication and preserves the artifact.

## Measurements

Debug build, warm local filesystem, other project tasks active. Fixture creation,
post-publication integrity assertions and cleanup are excluded from timings.
The payloads are small synthetic text, not decodable camera RAW or real metadata;
there is no geocoder, model inference, network transfer or receipt-store work.
These results describe publication-boundary overhead, not enriched-image throughput.

| Background root files | 50-image batch | Per-image median | Per-image p95 |
| --- | ---: | ---: | ---: |
| 0 | 0.764 s | 13.58 ms | 27.84 ms |
| 100,000 | 5.358 s | 107.48 ms | 118.37 ms |

p95 uses nearest rank over 50 publications. One batch per folder size was run;
the 4.594-second difference is an observation, not a controlled estimate of scan
cost alone. Per-image root scanning remains a meaningful scaling limitation.

The existing alternating 20-sample standalone benchmark also passes:

| Scan of 100,000 files | Median | p95 |
| --- | ---: | ---: |
| Earlier Foundation name-array implementation | 206.67 ms | 211.43 ms |
| Current streaming implementation | 38.96 ms | 44.57 ms |

The current median is close to the earlier streaming report's 39.28 ms. This run
does not establish a throughput improvement from the new allocation fast path;
the reduction in ordinary-filename construction follows from the code.
Memory and in-flight cancellation latency were not measured.

## Verification

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/LocalSyncIntegrationTests CODE_SIGNING_ALLOWED=NO
TEST_RUNNER_AAGEDAL_RECOVERY_BATCH_BENCHMARK=1 \
TEST_RUNNER_AAGEDAL_RECOVERY_SCAN_BENCHMARK=1 xcodebuild test \
  -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests/testLargeFolderRecoveryPublicationBatchBenchmark \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests/testLargeFolderRecoveryScanBenchmark \
  CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

Focused selection: 105 executed, 101 passed, four opt-in skips, zero failures.
Separate benchmarks: two passed, zero skips/failures. All final commands exit 0.
The initial sandboxed Xcode attempt failed on compiler/package-cache access;
approved execution resolved it.

Logs: `build/v3-recovery-batch-tests.log`, `build/v3-recovery-batch-benchmark.log`.
Results under `build/v3-preview-consistency/Logs/Test/`:

- `Test-AagedalFTPSync-2026.09.19_22-41-14-+0200.xcresult`
- `Test-AagedalFTPSync-2026.09.19_22-41-53-+0200.xcresult`

Unsigned test app: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.
Executable SHA-256:
`b2fd270394fda3a66a18cce49ffac40e977db1d7c19ddd4fe18b6d3e282defab`.

## Remaining work

The shared desktop inventory and active tasks showed other app work in progress;
this slice used isolated non-UI fixtures. The pending signed native recovery test
and observed reconciliation/retry remain unexecuted in this run. Rebuild the signed
UI app before that next test; the shared DerivedData currently contains an unsigned
test build. Full enriched-batch budgets, camera RAW, supported-OS, real-face
calibration and release acceptance remain open. No milestone or checklist gate is closed.
