# M5 reprocessing phase profile — 2026-09-21

Source: `f94c7569bdac35af5ce7ec103cc33e59da30a242` plus the instrumentation,
benchmark and records committed with this report, on `codex/version-3-0-plan`.
Host: macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`), arm64. Development
identity: 3.0.0 (38). No private results JSON was present; historical candidate
identity and checklist lanes are unchanged. The Photo Agent task was active;
no desktop automation was performed.

## Change

Local sessions accept an optional measurement observer for full directory listings
and fresh recovery admission. Durations use the monotonic continuous clock and
include failed/cancelled attempts. Normal sessions leave the observer unset and
do not read the measurement clock. The observer receives only operation type and
duration, with no paths or file contents. No listing, cancellation, collision,
snapshot or publication rule changes.

The existing enriched benchmark injects a lock-protected collector into its
reprocessing destination session. It prints counts and accumulated times separately
for preflight, publication plus audit, and unchanged-receipt repeat. These two
measured operations do not nest. `otherSeconds` is total minus the two measured
intervals, not a separate measurement of metadata processing. It includes filtering,
collision reservation, source evidence, hashing, metadata I/O and any scheduling
or observer overhead; publication also includes audit persistence.

Five samples per background size retain the existing 25 generated JPEG and 25
synthetic RAW/valid-XMP fixtures, deterministic geocoder, changed headline per
sample, reopened audit and byte-integrity assertions. All 500 publications and
500 unchanged-repeat skips pass. Every phase has exactly one observed destination
listing. Preflight/repeat each have 51 recovery checks and publication has 101,
confirming the earlier code-inspection counts within the actual pipeline.

## Measurements

Median seconds over five samples. Each column is independently aggregated, so
column medians need not sum to the median total.

| Background files | Phase | Total | Listing | Recovery admission | Other |
| ---: | --- | ---: | ---: | ---: | ---: |
| 0 | Preflight | 0.4103 | 0.0007 | 0.0043 | 0.4051 |
| 0 | Publication + audit | 0.7588 | 0.0007 | 0.0087 | 0.7495 |
| 0 | Current-receipt repeat | 0.1860 | 0.0007 | 0.0040 | 0.1813 |
| 100,000 | Preflight | 4.0627 | 0.7360 | 2.2059 | 1.1377 |
| 100,000 | Publication + audit | 6.5492 | 0.7253 | 4.2693 | 1.5605 |
| 100,000 | Current-receipt repeat | 3.8010 | 0.7206 | 2.1335 | 0.9156 |

Fresh recovery admission is the largest measured large-folder cost. The ratio of
its median to median total is about 65% for publication; directory listing is
about 11%. This replaces the earlier estimate from separate scan timings with
in-pipeline observations. It does not establish a speedup: processing behavior is
unchanged, the host is shared, and these are warm filesystem Debug measurements.

## Reproduction and verification

```sh
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

Focused selection: 61 executed, 57 passed, four other opt-in tests skipped, zero
failures, exit 0. Security, development-identity and diff checks pass. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.21_16-56-15-+0200.xcresult`.

The initial restricted build could not write compiler caches; approved Xcode
access resolved that environment limitation. Log:
`build/v3-reprocessing-profile.log`. The app-code debug dylib SHA-256 is
`f6d6e12f48089c54c15443a2626263f4e32c73f2b695b525b206b409c40dd9ab`, under
`build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.

## Next work and limits

Profile the unmeasured filtering/collision/evidence portion before optimizing it.
Investigate a faster fresh recovery scan only with equivalent late-artifact,
link, cancellation and error coverage; do not reuse a successful earlier scan
across asynchronous processing. Re-run controlled production geocoder/model
workloads and resource measurements on a quiet host. Native recovery, camera RAW,
real-face calibration, macOS 14 and final-candidate validation remain open.
No milestone or checklist acceptance gate is closed by this diagnostic change.
