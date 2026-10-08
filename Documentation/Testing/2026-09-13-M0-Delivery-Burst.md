# Aagedal FTP Sync delivery-latency benchmark

Recorded 2026-09-13 17:38:17 CEST on `macOS-27.0-arm64-arm-64bit-Mach-O; arm64; Model Name: MacBook Pro; Chip: Apple M5 Pro; Memory: 64 GB` with `Xcode 27.0 / Build version 27A266a` using the Debug configuration.

- Source: `e6735136d3bc41b8d20aef4f0295c5cfceba4f11; clean`.
- Command: `Scripts/run-delivery-latency-benchmark.py --directories 10 --subdirectories 5 --files 20 --iterations 5 --recent-files 20 --recent-file-bytes 4194304 --report Documentation/Testing/2026-09-13-M0-Delivery-Burst.md`.

## Fixture and method

- Loopback FTP and SFTP services exposed the same fixed tree: 10 top-level directories × 5 subdirectories × 20 files (1,000 files; 61 directories including the root). Only the eligible burst carried payload bytes.
- Service fixture versions: pyftpdlib 2.2.0, paramiko 5.0.0.
- 20 JPEG(s), each 4,194,304 bytes, had current modification dates and all other files used 2000-01-01. The sync job's one-hour recent-file filter therefore published exactly that burst. Payload files are deterministic transport fixtures, not decoded photographs.
- Each cell used one unrecorded warm-up and 5 measured iterations. Cold means a new protocol connection for each iteration; warm means a reused authenticated connection. Both states benefit from the host filesystem cache after warm-up.
- Full scan measures `EndpointSession.listFiles()`. First publication is timestamped when the destination accepts the first eligible file; burst completion includes authoritative listing, publication of every eligible file, and reconciliation before another sample starts.
- The historical comparison baseline was recorded on September 1, 2026 before completed-directory publication was implemented, using 100,000 files and five measured samples. Comparisons are shown only for matching fixture parameters.

## Results (seconds)

| Protocol | Connection | Metric | Median | p95 |
|---|---|---|---:|---:|
| FTP | Cold | Full scan | 0.156 | 0.160 |
| FTP | Warm | Full scan | 0.157 | 0.161 |
| FTP | Cold | First publication | 0.043 | 0.056 |
| FTP | Warm | First publication | 0.035 | 0.063 |
| FTP | Cold | Burst completion | 0.524 | 0.699 |
| FTP | Warm | Burst completion | 0.625 | 0.751 |
| SFTP | Cold | Full scan | 0.105 | 0.117 |
| SFTP | Warm | Full scan | 0.109 | 0.150 |
| SFTP | Cold | First publication | 0.044 | 0.073 |
| SFTP | Warm | First publication | 0.037 | 0.069 |
| SFTP | Cold | Burst completion | 0.791 | 1.043 |
| SFTP | Warm | Burst completion | 0.860 | 1.137 |

## Effective burst throughput

End-to-end payload throughput divides the 80.00 MiB eligible burst by median burst-completion time. It includes listing and reconciliation overhead and is therefore intentionally lower than raw transport throughput.

| Protocol | Connection | Median MiB/s |
|---|---|---:|
| FTP | Cold | 152.64 |
| FTP | Warm | 128.02 |
| SFTP | Cold | 101.08 |
| SFTP | Warm | 93.00 |

## Provisional transport budget

For this exact 20-file/80 MiB loopback fixture on the benchmark Mac, retain these
pre-enrichment regression gates for both protocols and connection states:

- first publication p95 no greater than 0.100 seconds;
- complete-burst p95 no greater than 1.500 seconds; and
- median effective throughput no lower than 50 MiB/s.

All measured cells pass those gates. They intentionally leave broad headroom for
normal scheduler and host variance while still detecting a material regression.
They are transport-pipeline budgets only: the fixture uses synthetic payloads and
does not decode metadata, geocode, recognize faces, measure peak memory, or exercise
cancellation. The 3.0 candidate still needs representative real-image enrichment,
memory and cancellation measurements plus the separate 100,000-file final smoke.

## Change from pre-implementation baseline

Not compared: this run differs from the historical 100,000-file, five-sample fixture.

p95 uses the nearest-rank method; with five or fewer samples it is the slowest observed iteration. This run used 5 measured samples per cell. Loopback absolute timings are informational and should be compared only with runs using the same fixture and build configuration.
