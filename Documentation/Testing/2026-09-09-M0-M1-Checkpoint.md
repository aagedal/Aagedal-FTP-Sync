# 3.0 compatibility and template-core checkpoint

Recorded 2026-09-09. Status **IMPLEMENTING**, no release candidate or human
acceptance claim. The ten-minute coordinator remains active; substantive progress
was made, so the no-progress counter remains zero. Human checklist results were
absent and have not been populated or modified.

## Source and implementation

- Starting app source: `adf995b6adf9eeb77cf49084c903b2ef2adac405`, version 2.9.2
  build 37, including the stable calendar-network fix `d2a5f05`.
- `176f773`: pinned dependency/Photo Agent provenance, design contracts, and
  executable geocoder/metadata/model probes. Protocol JSON files are proposed
  design fixtures, not evidence of implemented server compatibility.
- `dbecf40`: isolated Swift 6 `MetadataTemplates` package, macOS 14 minimum,
  strict parsing, explicit immutable date/zone context, dependency discovery,
  one-pass resolution and atomic preservation/keyword outcomes. No production
  app dependency or template activation changed in these commits.
- `f14c223`: compatible download-name checkpoints, lexical filename filtering,
  seven regression tests and isolated benchmark storage/logging/reporting.
- Main coordinator integrated disjoint sub-agent work and reviewed source.
  A separate contract reviewer examined the parser and found no blocking issue.
  Existing writer/server limits still need enforcement during app integration.

## Observed verification

| Area | Evidence | Limit |
| --- | --- | --- |
| Template core | 19 tests / 50 invocations pass, zero skips; independent review | No app UI, activation, persistence or real EXIF interpretation yet |
| Pinned metadata dependency | Offline/online geocoder and synthetic JPEG/XMP round trips pass | Selected APIs/formats only; retain 2.0.0 initially |
| Actual signed model | Descriptor signature, ZIP/package hashes, model interface and three synthetic inferences pass | No real-face accuracy, archive extraction or installer lifecycle test |
| Hosted descriptor/signature | HTTP 200, no redirect, byte-identical to locally verified artifacts | Hosted model archive was not downloaded |
| OS boundary | Both probes compile with macOS 14 deployment target; run on macOS 27 beta | Sonoma runtime remains untested |

Template verification command (workspace-local caches avoid sandbox cache writes):

```sh
CLANG_MODULE_CACHE_PATH="$PWD/Packages/MetadataProcessing/.build/clang-module-cache" swift test --package-path Packages/MetadataProcessing --cache-path Packages/MetadataProcessing/.build/cache --config-path Packages/MetadataProcessing/.build/config --security-path Packages/MetadataProcessing/.build/security --disable-sandbox
```

Detailed reproducible evidence and remaining gates:
[dependency](3.0-M0-Dependency-Compatibility.md),
[face/model](3.0-M0-Face-Compatibility.md),
[template/calendar design](3.0-M0-Template-Compatibility.md), and
[package contract](../../Packages/MetadataProcessing/README.md).

## Baseline investigation

The unchanged app's 100,000-file, five-sample delivery run was interrupted after
approximately twelve minutes with exit 75 and no complete result payload. This
is **not a passing performance baseline**. Log: `/tmp/ftp-m0-baseline.log`;
two-second test-process sample: `/tmp/ftp-m0-benchmark-sample.txt`.
Copies of baseline, sample, smoke and focused-test logs are retained under ignored
`build/m0-delivery/`; geocoder logs are under ignored `build/m0-geocoder/`.

The sample showed repeated cumulative JSON mapping encoding in
`DownloadNamingSession.map`, introduced by `94c0dd52` after the historical 2.7
benchmark. For 1,000 directories containing 100 files each, that path serializes
50,050,000 mapping entries per fresh listing, plus sorting and dictionary copies.
The sample reported physical footprint 134.2 MB and peak 437.2 MB for that test
process; a single sampled process is not a controlled burst-memory measurement.
The installed app and other tasks were active on the same host, so timing is
informational. The installed app was not terminated or replaced.

The harness also used a default download-manifest repository even though source
signatures were isolated. Subsequent runs now isolate both repositories and name
maps in one disposable directory. The interrupted run may have left records
under fresh benchmark job UUIDs in the normal app-support manifest; no existing
user data or unverified record was deleted. This must be considered when comparing
old harness runs. The updated service logger uses a temporary file to avoid
unread-pipe backpressure, and reports omit mismatched historical comparisons.

A 1,000-file, one-sample smoke run of the isolated harness passed in 4.832 seconds,
publishing exactly the expected one recent file over each protocol. Exit 0;
`/tmp/ftp-m0-delivery-smoke.log`. See [smoke measurements](3.0-M0-Delivery-Smoke.md).
It validates harness behavior, not the required 100,000-file or real-image burst
budget. Host inventory confirmed MacBook Pro, Apple M5 Pro, 64 GB RAM, macOS 27.0
beta `26A5425a`, Xcode 26.6 build `17F113`. No hardware or OS coverage beyond this
host is claimed.

## Next integration gates

The compatible checkpoint implementation accumulates associations without copying
the full map per directory, then atomically saves before source export/removal and
the completed-listing return. It retains flat JSON and existing replacement mode.
Five new tests cover deterministic save frequency, warm no-rewrite, alias restart,
all removal overloads, failed-save retry and cancellation; all 24 download-naming
tests passed. A second independent agent reviewed the actual patch and transfer
boundaries with no actionable finding.

The full 100,000-file five-sample run then passed in 678.631 seconds. Observed
first-publication p95: FTP cold 0.258 s / warm 0.312 s; SFTP cold 0.175 s / warm
0.155 s. See [checkpoint-only baseline](3.0-M0-Delivery-Baseline.md) for all
metrics, source hashes and load/profiling caveats. Its historical comparison
predates early delivery and cannot establish this fix's speedup.

A late sample showed additional time in `FileFilter.includesFileType`, where a
relative file URL caused repeated working-directory filesystem queries. The
subsequent lexical extension change removes that work for normal scanner names,
retains a narrow legacy fallback for empty/dot-path inputs, and adds two edge-case
tests. Independent review found no actionable issue. Sample retained in
`build/m0-delivery/ftp-m0-benchmark-late-sample.txt`.

Full app validation for the code committed as `f14c223` passed: **480 passed,
15 opt-in skips, zero failures** (495 total). Command:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Log: `/tmp/ftp-m0-full-tests.log`, also retained in `build/m0-delivery/`.
The opt-in release, external-server and signed-UI gates are not counted as passes.
No new app feature UI is present yet; the checklist's previously observed browser
tests do not substitute for future 3.0 app GUI testing.

Select concrete burst throughput/memory/cancellation budgets before comparing the
integrated 3.0 pipeline. The final-commit large-fixture smoke is recorded separately
from the checkpoint-only five-sample baseline; do not infer statistical equivalence.

The [final combined-fix smoke](3.0-M0-Delivery-Final-Smoke.md) on exact source
`f14c223` passed the full 100,000-file fixture with one measured sample per cell
and an unrecorded warm-up, exit 0, test duration 183.620 seconds. First publication:
FTP cold/warm 0.229/0.209 seconds; SFTP 0.146/0.140 seconds. These are single
observations, not statistical p95 estimates. Final command:

```sh
build/3.0-benchmark-venv/bin/python Scripts/run-delivery-latency-benchmark.py --iterations 1 --report Documentation/Testing/3.0-M0-Delivery-Final-Smoke.md
```

Final log: `build/m0-delivery/ftp-m0-final-benchmark.log`. All benchmark processes
completed and their disposable fixture/state directories were cleaned by the
harness. No installed application was replaced, signed release prepared, or
publication/deployment performed.

Continue explicit activation and resolved-change integration with v3 storage
separation, bounded geocoding, companion exporter coordination and real-model
fixtures. M0 is incomplete and M1 is partial. All final-candidate agent/user
checklist entries remain unrun; no readiness notification is warranted.
