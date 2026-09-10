# Versioned stores and original capture dates

Recorded 2026-09-10, starting from clean `78370de` on
`codex/version-3-0-plan`; reviewed app/package changes committed as `c0de968`.
Status remains **IMPLEMENTING**; no milestone or candidate
gate is completed by this prerequisite slice. Human checklist results remain
absent and untouched. The ten-minute coordinator remains active, with zero
consecutive cycles lacking substantive progress.

## Implementation

All nine JSON stores now support an explicitly selected v3 envelope containing
format, schema version, store identity and payload. Normal repository defaults
remain legacy. No startup code chooses v3 or migrates personal data. A migration
driver must initialize the complete store set: a missing v3 primary cannot load
as empty or be recreated by an ordinary save. Unsupported, unidentified and
wrong-store primaries or backups are retained without overwrite. Only damaged
payloads inside supported envelopes may use existing compatible backup recovery.
Calendar diagnostics expose a read failure through the coordinator instead of
silently treating an incompatible v3 log as empty.

Legacy encoders, date strategies, interchange formats and backup behavior are
preserved. The manifest actor validates cached v3 file identity and reloads after
observed replacements or in-place changes. Backup-derived results are not cached;
future-version replacement of a recovery file must be noticed on the next read.
This assumes trusted stable directories and cooperating writers, not hostile
same-user filesystem manipulation. Cross-store consistency remains a caller gate.

An injected set of retained credential IDs protects endpoint/profile credentials
from post-save and job-removal garbage collection. New staged credentials still
roll back on a failed save. No caller yet computes this set from retained 2.9
stores; calendar device-credential deletion needs its own retention integration.
No credential bytes are copied and tests use an in-memory fake Keychain.

`MetadataCaptureDateReader` reads original EXIF or explicit XMP sidecar metadata
without changing source bytes. It strictly checks calendar components, ASCII,
fractional seconds, whole-minute offsets and conflicting representations. EXIF
original takes precedence even when malformed; missing original capture never
falls back to generic creation, modification or processing dates. Offset-free
input requires a persisted zone. A bounded Foundation TZif offset inventory plus
actual zone-rule validation detects nonexistent and ambiguous local times,
including half-hour folds. Explicit offset and exact nanoseconds remain in
provenance. Floating-point fractions cannot advance the original civil day.

The package date formatter now uses proleptic Gregorian conversion for years
1–9999, avoiding Foundation's historical calendar cutover. It floors the stored
reference-epoch value before adding integral epoch and zone offsets, preserving
representable instants immediately before midnight. Legacy scheduling parsing is
unchanged; production activated contexts do not yet call this reader.

## Verification

Full Xcode app suite: **566 discovered, 551 passed, 15 opt-in skips, zero failures**,
exit 0 at 10:40:27 Europe/Oslo, 17.759 seconds of test execution. This includes
12 capture-reader, four codec, seven repository, six calendar-storage and two new
credential-retention tests, alongside the existing integration and recovery tests.
Tested source was the uncommitted slice subsequently saved without code changes
as `c0de968`; documentation was also dirty. Commands:

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Log: `build/m1-v3-codec-capture/full-tests.log`, SHA-256
`d2c8e04c3e4ea72db7d5e8a075f95860862e1a7eacadc6bf1ab354a82f479f3a`.
Result bundle under Xcode DerivedData's `Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/`:
`Test-AagedalFTPSync-2026.09.10_10-40-05-+0200.xcresult`.
Host: Apple silicon, macOS 27.0 build 26A428, Xcode 26.6 build 17F113.
App remains development 2.9.2 (37), unsigned test build in DerivedData.

The initial integrated run had one test assertion failure: nested write-policy
Sets encode in nondeterministic JSON array order. The round-trip test now compares
all semantic state members instead of requiring identical encoded bytes. An added
fixed-zone test also exposed valid Foundation GMT aliases without TZif data; those
use their verified canonical fixed-offset identity. The full rerun above covers
the corrected source and all 12 capture tests. The initial log is retained at
`build/m1-v3-codec-capture/initial-tests.log`.

Pure package suite: **33 test functions pass**, including parameterized Gregorian
goldens, fixed zones, ancient years, negative epochs and midnight boundaries:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/Packages/MetadataProcessing/.build/clang-module-cache" \
swift test --package-path Packages/MetadataProcessing \
  --cache-path Packages/MetadataProcessing/.build/cache \
  --config-path Packages/MetadataProcessing/.build/config \
  --security-path Packages/MetadataProcessing/.build/security --disable-sandbox
```

Log `build/capture-date-tests/package-results.log`, SHA-256
`ba550c98f89e0fe95b3983e1cf7381b1130401826bc34227cf4d51841bfa36bc`.
The separate copied-source capture harness also passed 12 tests with actual pinned
SwiftMediaMetadata 2.0.0 and synthetic JPEG/XMP fixtures; its narrower integration
evidence is superseded by the full app run. No private images were used.

Independent review caught and resolved stale manifest backup caching, hidden
incompatible-backup errors, malformed present tags being treated as absent,
fractional midnight rounding and pre-1582 formatter disagreement. The reviewer
also checked all repository adapters and retained credential cleanup boundaries.

The shared desktop still has active media-app coordinators. Actual new app UI
testing was deferred; no GUI, macOS 14 runtime, production migration or final
checklist case is credited by these development tests. The installed stable app
remains unchanged.

## Next integration gates

1. Build a read-only cross-store converter/validator and closed-writer startup
   lifecycle before selecting v3. Add strict pre-open SQLite schema handling,
   versioned name mappings, complete directory inventory, current-v3 recovery and
   retained endpoint plus calendar credential reachability. Snapshot APIs alone
   do not make independently changing stores consistent.
2. Persist complete source/activation values and independent processing settings;
   enforce configuration/calendar capability boundaries before any activated
   source can reach older clients. Integrate strict capture context and explicit
   fallback zone with asynchronous preview and transfer/reprocessing.
3. Handle existing non-UTF-8 IPTC without reinterpreting retained bytes. Add partial
   completion audit and source-removal guards before enabling processing UI.
4. Continue bounded providers, face library/model lifecycle, measured delivery
   budgets, supported-OS and actual GUI verification from the full plan.
