# Aagedal FTP Sync delivery-latency benchmark

Recorded 2026-10-18 19:23:42 CEST on `macOS-27.0.1-arm64-arm-64bit-Mach-O; arm64; Model Name: MacBook Pro; Chip: Apple M5 Pro; Memory: 64 GB` with `Xcode 27.0 / Build version 27A266a` using the Debug configuration.

- Source: `4b95876db8d7416f86ddd6864efe5770288576d9; dirty`.
- Command: `Scripts/run-delivery-latency-benchmark.py --directories 10 --subdirectories 5 --files 20 --iterations 5 --recent-files 20 --recent-file-bytes 4194304 --report build/2026-10-18-current-delivery-resource-burst.md`.

## Fixture and method

- Loopback FTP and SFTP services exposed the same fixed tree: 10 top-level directories × 5 subdirectories × 20 files (1,000 files; 61 directories including the root). Only the eligible burst carried payload bytes.
- Service fixture versions: pyftpdlib 2.2.0, paramiko 5.0.0.
- 20 JPEG(s), each 4,194,304 bytes, had current modification dates and all other files used 2000-01-01. The sync job's one-hour recent-file filter therefore published exactly that burst. Payload files are deterministic transport fixtures, not decoded photographs.
- Each cell used one unrecorded warm-up and 5 measured iterations. Cold means a new protocol connection for each iteration; warm means a reused authenticated connection. Both states benefit from the host filesystem cache after warm-up.
- Full scan measures `EndpointSession.listFiles()`. First publication is timestamped when the destination accepts the first eligible file; burst completion includes authoritative listing, publication of every eligible file, and reconciliation before another sample starts.
- Peak resident memory is sampled in the XCTest process while each destination import still holds its payload data. It includes the test runner and loaded app code, so it is an absolute process-footprint ceiling for this fixture rather than an allocation delta.
- Cancellation is requested after a real remote listing and export reaches a deliberately suspended destination import. The measurement ends only after rollback, endpoint closure and child-task draining return `CancellationError`; no destination path may be committed.
- The historical comparison baseline was recorded on September 1, 2026 before completed-directory publication was implemented, using 100,000 files and five measured samples. Comparisons are shown only for matching fixture parameters.

## Results (seconds)

| Protocol | Connection | Metric | Median | p95 |
|---|---|---|---:|---:|
| FTP | Cold | Full scan | 0.136 | 0.243 |
| FTP | Warm | Full scan | 0.210 | 0.260 |
| FTP | Cold | First publication | 0.027 | 0.028 |
| FTP | Warm | First publication | 0.026 | 0.027 |
| FTP | Cold | Burst completion | 0.272 | 0.275 |
| FTP | Warm | Burst completion | 0.270 | 0.285 |
| SFTP | Cold | Full scan | 0.088 | 0.093 |
| SFTP | Warm | Full scan | 0.083 | 0.084 |
| SFTP | Cold | First publication | 0.030 | 0.031 |
| SFTP | Warm | First publication | 0.028 | 0.029 |
| SFTP | Cold | Burst completion | 0.356 | 0.364 |
| SFTP | Warm | Burst completion | 0.366 | 0.370 |

## Effective burst throughput

End-to-end payload throughput divides the 80.00 MiB eligible burst by median burst-completion time. It includes listing and reconciliation overhead and is therefore intentionally lower than raw transport throughput.

| Protocol | Connection | Median MiB/s |
|---|---|---:|
| FTP | Cold | 294.03 |
| FTP | Warm | 296.64 |
| SFTP | Cold | 224.64 |
| SFTP | Warm | 218.39 |

## Peak resident memory

| Protocol | Connection | Median MiB | p95 MiB |
|---|---|---:|---:|
| FTP | Cold | 137.7 | 140.6 |
| FTP | Warm | 146.6 | 149.5 |
| SFTP | Cold | 160.7 | 161.1 |
| SFTP | Warm | 157.2 | 161.3 |

## Cancellation latency

| Protocol | Median seconds | p95 seconds |
|---|---:|---:|
| FTP | 0.000 | 0.001 |
| SFTP | 0.000 | 0.000 |

## Change from pre-implementation baseline

Not compared: this run differs from the historical 100,000-file, five-sample fixture.

p95 uses the nearest-rank method; with five or fewer samples it is the slowest observed iteration. This run used 5 measured samples per cell. Loopback absolute timings are informational and should be compared only with runs using the same fixture and build configuration.

## Current-source interpretation and existing budgets

The existing pre-enrichment gates for this exact 1,000-file/20-file/80 MiB
fixture are first-publication p95 ≤ 0.100 s, burst-completion p95 ≤ 1.500 s,
and median effective throughput ≥ 50 MiB/s. All four protocol/connection cells
pass in this run. The provisional absolute test-process footprint ceiling of
256 MiB and cancellation p95 ceiling of 0.100 s also pass: the maximum resident
sample is 161.281 MiB and the slowest cancellation is 0.000516 s. All ten
cancellation runs return CancellationError without committing a destination path.

The XCTest result contains one passed test, zero failures and zero skips (exit 0);
its test body took 11.398 seconds. The report uses the existing BenchmarkDestination,
which accepts synthetic payloads in memory. It does not measure durable local
publication, image decoding, geocoding, face recognition, actual camera media,
remote-listing/model cancellation, or application UI stop latency. This shared-host
Debug observation is not quiet-host or final signed-candidate acceptance, nor a
claimed speed improvement over historical runs.

The command above was run with
`AFTPSYNC_TEST_DERIVED_DATA=build/continuation-tests` using
`build/transport-test-venv/bin/python`. The runner now honors that build-location
override and otherwise uses its temporary fixture directory for DerivedData,
with automatic package resolution disabled. No production app source changed.
Pending sidebar/shared-server setup changes were present. The exact source diff
was captured in ignored `build/current-delivery-resource-source.patch`, SHA-256
`5a34bd285f10f5966e46a24ec10a8391bca3bf26c437a587189b111ffcef4a45`.

Raw samples: `build/current-delivery-resource-burst.json`.
Log: `build/current-delivery-resource-burst.log`.
Summary: `build/current-delivery-resource-summary.json`.
Result: `build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.18_19-23-10-+0200.xcresult`.
Independent source/report review found no blockers.

The earlier SFTP completion-budget miss did not reproduce in this workload/run.
A final candidate still needs its controlled performance checks and the separate
large-tree/enrichment/production publication gates. PHP/MariaDB remains unrun in
this cycle because the Docker daemon socket is absent. The daemon was not started
while desktop use is deferred. Native setup, supported-OS, VoiceOver and remaining
M0–M6 acceptance gates stay open.

Signed native test compilation was restored after both unsigned benchmarks,
without executing UI tests (`build/current-delivery-native-ready.log`). Strict
deep signature verification passes using system trust services. The initial
restricted read returned `CSSMERR_TP_NOT_TRUSTED`; the approved verification passed
without changing the app, certificates or system trust settings.
