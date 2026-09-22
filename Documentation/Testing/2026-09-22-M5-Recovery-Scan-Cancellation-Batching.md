# M5 recovery scan cancellation batching — 2026-09-22

The enriched reprocessing path admits the destination at the start of the
batch, after each metadata resolution, and again before each publication. Each
admission must freshly enumerate the entire destination root because a retained
transaction can appear while metadata resolution is suspended. With 100,000
unrelated files, the existing optimized profile attributed most elapsed time to
these repeated scans.

`LocalEndpointSession.validateMetadataRecoveryIsResolved()` now checks task
cancellation every 256 directory entries instead of every entry. It still checks
before the first entry and after EOF, examines every hidden name, and starts a
new directory scan at every admission. The largest cancellation polling gap is
256 directory entries. No recovery result is cached.

## Verification

The paired full-path runs used the same Release test configuration, one sample,
the same derived data path, and the opt-in `testLargeFolderEnrichedReprocessingBenchmark`.
The baseline was built and executed before the source edit; the changed build
also ran `testReprocessingRequiresRecoveryBeforePreflightOrWrites`,
`testScopedImageRecoveryPreservesReviewedConflictsAndResumesAfterReopening`,
and the entire `LocalMatchingPublicationTests` class. The changed run passed:
31 tests executed, four opt-in skips, zero failures. Its new
`testRecoveryAdmissionScansPastCancellationBatchesAndChecksFreshState` verifies
that a retained recovery directory is found among 600 ordinary files and that
removing it changes the next admission result. The benchmark retains its byte,
metadata, receipt, conflict, and publication-count assertions.

```sh
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_BENCHMARK=1 \
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_SAMPLES=1 \
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests/testLargeFolderEnrichedReprocessingBenchmark \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG'
```

The modified run added the two recovery test selectors and
`-only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests`.
The `DEBUG` condition is needed by existing test-only face-context APIs; this
is an optimized test build, not a shipping Release build.

| 100,000 background files | Baseline recovery admission | Batched recovery admission | Baseline total | Batched total |
| --- | ---: | ---: | ---: | ---: |
| Preflight, 51 admissions | 2.743 s | 2.288 s | 4.956 s | 3.741 s |
| Publication and audit, 101 admissions | 6.035 s | 4.382 s | 8.011 s | 5.962 s |
| Current receipt repeat, 51 admissions | 2.896 s | 2.333 s | 4.414 s | 3.539 s |

These full-path runs were not simultaneous or controlled for system load. The
small-folder case also became much faster in the second run, so the table alone
cannot attribute its entire change to cancellation batching. To isolate the
scan loop, a disposable optimized Swift program alternated the previous and
new loops, each scanning the same 100,000-entry directory 25 times per block,
for eight paired iterations. Median block time was 1.144 s before and 1.066 s
after (about 6.8% lower); summed block time was 9.244 s before and 8.892 s
after (about 3.8% lower). This supports a modest scan improvement, with
variation across pairs. The program and its disposable files were kept in
`/tmp`, outside the repository.

The path still has linear recovery admission cost per boundary. Larger
production directories, cold caches, real geocoding and face models, and
release candidate hardware remain outside this evidence.
