# Aagedal FTP Sync delivery-latency benchmark

Recorded 2026-09-13 18:31:22 CEST on `macOS-27.0-arm64-arm-64bit-Mach-O; arm64; Model Name: MacBook Pro; Chip: Apple M5 Pro; Memory: 64 GB` with `Xcode 27.0 / Build version 27A266a` using the Debug configuration.

- Source: `b270e11d1c362a400b57b9aa771727885f00a19c; clean`.
- Command: `Scripts/run-delivery-latency-benchmark.py --directories 10 --subdirectories 5 --files 20 --iterations 5 --recent-files 20 --recent-file-bytes 4194304 --report Documentation/Testing/2026-09-13-M0-Delivery-Resource-Burst.md`.

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
| FTP | Cold | Full scan | 0.128 | 0.129 |
| FTP | Warm | Full scan | 0.137 | 0.140 |
| FTP | Cold | First publication | 0.030 | 0.038 |
| FTP | Warm | First publication | 0.025 | 0.028 |
| FTP | Cold | Burst completion | 0.645 | 0.683 |
| FTP | Warm | Burst completion | 0.625 | 0.659 |
| SFTP | Cold | Full scan | 0.090 | 0.095 |
| SFTP | Warm | Full scan | 0.072 | 0.076 |
| SFTP | Cold | First publication | 0.079 | 0.099 |
| SFTP | Warm | First publication | 0.088 | 0.094 |
| SFTP | Cold | Burst completion | 1.436 | 1.667 |
| SFTP | Warm | Burst completion | 1.747 | 1.843 |

## Effective burst throughput

End-to-end payload throughput divides the 80.00 MiB eligible burst by median burst-completion time. It includes listing and reconciliation overhead and is therefore intentionally lower than raw transport throughput.

| Protocol | Connection | Median MiB/s |
|---|---|---:|
| FTP | Cold | 124.02 |
| FTP | Warm | 128.02 |
| SFTP | Cold | 55.71 |
| SFTP | Warm | 45.80 |

## Peak resident memory

| Protocol | Connection | Median MiB | p95 MiB |
|---|---|---:|---:|
| FTP | Cold | 132.0 | 135.0 |
| FTP | Warm | 141.8 | 144.9 |
| SFTP | Cold | 153.5 | 153.8 |
| SFTP | Warm | 154.1 | 154.7 |

## Cancellation latency

| Protocol | Median seconds | p95 seconds |
|---|---:|---:|
| FTP | 0.000 | 0.001 |
| SFTP | 0.001 | 0.001 |

## Change from pre-implementation baseline

Not compared: this run differs from the historical 100,000-file, five-sample fixture.

p95 uses the nearest-rank method; with five or fewer samples it is the slowest observed iteration. This run used 5 measured samples per cell. Loopback absolute timings are informational and should be compared only with runs using the same fixture and build configuration.

## Resource-gate interpretation

For this pre-enrichment transport fixture, use a provisional absolute XCTest/app-code
process-footprint ceiling of 256 MiB and a publication-stage cancellation p95 of no
more than 0.100 seconds. The observed maximum footprint was 154.7 MiB and the slowest
cancellation was 0.0015 seconds; all ten cancelled runs returned `CancellationError`
without committing a destination path. These gates pass with substantial headroom.

The memory rows are cumulative within one test process, so the final SFTP values are
the conservative ceiling after the preceding FTP samples rather than isolated SFTP
allocation costs. Cancellation begins only after a real remote listing and export has
reached the controlled destination suspension. Separate enriched-image/model memory,
cancellation during remote listing/model work, and application-UI stop latency remain
release-candidate gates.

This run did not satisfy the earlier transport-only completion gates in every cell:
SFTP cold/warm p95 completion was 1.667/1.843 seconds against 1.500 seconds, and warm
median throughput was 45.80 MiB/s against 50 MiB/s. First publication still passed.
Do not weaken the established gate from this single slower sample; repeat under a
controlled candidate run and investigate if the result reproduces.
