# Aagedal FTP Sync delivery-latency benchmark

Recorded 2026-10-18 19:33:09 CEST on `macOS-27.0.1-arm64-arm-64bit-Mach-O; arm64; Model Name: MacBook Pro; Chip: Apple M5 Pro; Memory: 64 GB` with `Xcode 27.0 / Build version 27A266a` using the Debug configuration.

- Source: `4b95876db8d7416f86ddd6864efe5770288576d9; dirty`.
- Command: `Scripts/run-delivery-latency-benchmark.py --directories 100 --subdirectories 10 --files 100 --iterations 5 --recent-files 1 --recent-file-bytes 0 --report build/2026-10-18-current-delivery-100k.md`.

## Fixture and method

- Loopback FTP and SFTP services exposed the same fixed tree: 100 top-level directories × 10 subdirectories × 100 files (100,000 files; 1,101 directories including the root). Only the eligible burst carried payload bytes.
- Service fixture versions: pyftpdlib 2.2.0, paramiko 5.0.0.
- 1 JPEG(s), each 0 bytes, had current modification dates and all other files used 2000-01-01. The sync job's one-hour recent-file filter therefore published exactly that burst. Payload files are deterministic transport fixtures, not decoded photographs.
- Each cell used one unrecorded warm-up and 5 measured iterations. Cold means a new protocol connection for each iteration; warm means a reused authenticated connection. Both states benefit from the host filesystem cache after warm-up.
- Full scan measures `EndpointSession.listFiles()`. First publication is timestamped when the destination accepts the first eligible file; burst completion includes authoritative listing, publication of every eligible file, and reconciliation before another sample starts.
- Peak resident memory is sampled in the XCTest process while each destination import still holds its payload data. It includes the test runner and loaded app code, so it is an absolute process-footprint ceiling for this fixture rather than an allocation delta.
- Cancellation is requested after a real remote listing and export reaches a deliberately suspended destination import. The measurement ends only after rollback, endpoint closure and child-task draining return `CancellationError`; no destination path may be committed.
- The historical comparison baseline was recorded on September 1, 2026 before completed-directory publication was implemented, using 100,000 files and five measured samples. Comparisons are shown only for matching fixture parameters.

## Results (seconds)

| Protocol | Connection | Metric | Median | p95 |
|---|---|---|---:|---:|
| FTP | Cold | Full scan | 10.563 | 12.935 |
| FTP | Warm | Full scan | 9.492 | 9.567 |
| FTP | Cold | First publication | 0.197 | 0.230 |
| FTP | Warm | First publication | 0.200 | 0.222 |
| FTP | Cold | Burst completion | 13.311 | 13.923 |
| FTP | Warm | Burst completion | 13.502 | 13.735 |
| SFTP | Cold | Full scan | 6.607 | 6.812 |
| SFTP | Warm | Full scan | 5.133 | 6.401 |
| SFTP | Cold | First publication | 0.127 | 0.127 |
| SFTP | Warm | First publication | 0.123 | 0.133 |
| SFTP | Cold | Burst completion | 8.475 | 8.907 |
| SFTP | Warm | Burst completion | 8.466 | 8.600 |

## Effective burst throughput

End-to-end payload throughput divides the 0.00 MiB eligible burst by median burst-completion time. It includes listing and reconciliation overhead and is therefore intentionally lower than raw transport throughput.

| Protocol | Connection | Median MiB/s |
|---|---|---:|
| FTP | Cold | 0.00 |
| FTP | Warm | 0.00 |
| SFTP | Cold | 0.00 |
| SFTP | Warm | 0.00 |

## Peak resident memory

| Protocol | Connection | Median MiB | p95 MiB |
|---|---|---:|---:|
| FTP | Cold | 307.7 | 358.9 |
| FTP | Warm | 343.2 | 352.0 |
| SFTP | Cold | 364.2 | 366.5 |
| SFTP | Warm | 357.0 | 365.6 |

## Cancellation latency

| Protocol | Median seconds | p95 seconds |
|---|---:|---:|
| FTP | 0.000 | 0.000 |
| SFTP | 0.000 | 0.000 |

## Change from pre-implementation baseline

Negative values are improvements.

| Protocol | Connection | Metric | Median change | p95 change |
|---|---|---|---:|---:|
| FTP | Cold | Full scan | +0.201s (+1.9%) | +1.982s (+18.1%) |
| FTP | Warm | Full scan | +0.304s (+3.3%) | +0.037s (+0.4%) |
| FTP | Cold | First publication | -15.496s (-98.7%) | -19.201s (-98.8%) |
| FTP | Warm | First publication | -15.681s (-98.7%) | -18.543s (-98.8%) |
| SFTP | Cold | Full scan | +2.426s (+58.0%) | +2.052s (+43.1%) |
| SFTP | Warm | Full scan | +0.779s (+17.9%) | +1.733s (+37.1%) |
| SFTP | Cold | First publication | -11.436s (-98.9%) | -11.724s (-98.9%) |
| SFTP | Warm | First publication | -9.697s (-98.7%) | -12.131s (-98.9%) |

p95 uses the nearest-rank method; with five or fewer samples it is the slowest observed iteration. This run used 5 measured samples per cell. Loopback absolute timings are informational and should be compared only with runs using the same fixture and build configuration.

## Current-source scope and interpretation

This historical matching 100×10×100/five-sample traversal fixture passes its
correctness assertions: one eligible path is published per measured run, full
listings contain exactly 100,000 paths, and ten cancellation trials leave no
committed destination. The test body completed in 454.500 seconds, exit 0; the
xcresult summary records one passed test, zero failures and zero skips.

First publication begins before complete traversal: FTP cold/warm p95 is
0.230/0.222 s and SFTP cold/warm p95 is 0.127/0.133 s. Complete traversal and
reconciliation still take materially longer, as recorded above. The single
eligible file is empty, so the generated 0.00 MiB/s rows are arithmetic placeholders,
not a payload-throughput measurement.

Cancellation p95 is approximately 0.000456 s for FTP and 0.000421 s for SFTP;
the generated table rounds those nonzero observations to three decimal places.

The largest sampled resident footprint is 366.5 MiB, cumulative within the hosted
test process. The 256 MiB ceiling and latency budgets established for the separate
1,000-file/80 MiB burst do not establish a large-tree resource or latency pass.
Controlled candidate measurements and an explicit applicable scale budget remain
necessary. Historical comparison percentages are informational: this is a shared
host on a newer OS/source state, not a matched controlled experiment or a claimed
speed improvement from this change. No production optimization was introduced.
SFTP full scans are slower than the historical baseline in these observations;
a quiet matched-source/build repeat is needed before attributing a regression.

The destination is the existing synthetic in-memory BenchmarkDestination. This
run does not measure durable local grouped publication, image decoding, camera
RAW/XMP fidelity, enrichment/model memory, remote-listing/model cancellation or
native UI stop latency. It does not close final M0/M5 or release acceptance.

The runner used `AFTPSYNC_TEST_DERIVED_DATA=build/continuation-tests` and
`build/transport-test-venv/bin/python`. Application source was unchanged from the
preceding burst run; pending sidebar/shared-server setup changes remained present.
That exact tracked source diff is captured in ignored
`build/current-delivery-resource-source.patch`, SHA-256
`5a34bd285f10f5966e46a24ec10a8391bca3bf26c437a587189b111ffcef4a45`.

Raw samples: `build/current-delivery-100k.json`.
Log: `build/current-delivery-100k.log`.
Summary: `build/current-delivery-100k-summary.json`.
Result: `build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.18_19-25-20-+0200.xcresult`.
No desktop interaction was attempted, following the user's requested wait.
Independent source/sample review found no interpretation blockers. Signed native
test compilation was restored after both unsigned benchmarks, without executing
UI tests (`build/current-delivery-native-ready.log`).
