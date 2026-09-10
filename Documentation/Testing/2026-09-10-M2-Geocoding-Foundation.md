# M2 geocoding foundation — 2026-09-10

Implementation commit: `de33e98`, following clean baseline `c702ed7`.

Development implementation and validation checkpoint. No production geocoding setting,
lookup, metadata write or manual acceptance case is enabled by these components.

## Scope

- Pure effective-coordinate resolution: RAW prefers a valid complete XMP pair;
  embedded images prefer EXIF, with whole-pair fallback. Scheduled GPS obeys its
  field-specific overwrite policy. Invalid inputs and conflicting valid pairs retain
  diagnostics; zero/negative coordinates are valid and sources are never combined.
- A shared actor per provider configuration bounds unique work, coalesced callers,
  worker concurrency and TTL/LRU cache. Keys include exact coordinates, concrete locale,
  provider/version/dataset. Each caller's deadline includes queue time. Cancellation
  leaves other coalesced callers intact, and an uncooperative cancelled provider keeps
  its worker slot until it actually returns. Abandoned results cannot populate cache
  or impose new backoff. Failure backoff is bounded; no implicit provider switch occurs.
- Offline adapter uses pinned SwiftMediaMetadata 2.0.0 and its bundled GeoNames data.
  Its lazy database construction runs on the service's detached provider worker.
  Distance in kilometres is converted to metres and checked against an explicit default
  50 km policy. Country uses the requested locale; city retains the dataset spelling.
  A nearby settlement is not a verified administrative boundary or exact venue.

Dataset SHA-256:
`1c0d66422b009340135398674ec93d69366776917be9e9ef179cf1457cceb26b`.
No dependency upgrade or Photo Agent working-tree change was made. Preserve GeoNames
attribution at distribution. The dependency itself uses Float coordinates for its
nearest-neighbour tree; this service adds no spatial rounding to cache keys.

## Integration constraints

Production preview, transfer and reprocessing still use their prior literal pipeline.
Before connecting these components, implement persisted local settings, independent
City/Country policies, activated template context, provenance and source-removal guards.
Online adapters, supported-OS tests, real rural/coastal/border fixtures and delivery
benchmarks remain pending. Ocean/urban threshold tests do not establish border accuracy.

Independent review identified a pre-existing RAW writer distinction: an existing
sidecar without GPS currently allows scheduled fill without considering embedded EXIF.
The plan's effective-pair policy prefers embedded EXIF in that case. Align actual
assessment/write and resolver inputs together before production integration; do not
claim the new pure resolver changes legacy RAW behavior already.

Actual native GUI selection is not repeated this cycle: the preceding isolated unique
QA launch timed out after 722.8949 seconds, and this slice has no new UI. That failed
observation remains an open gate, not a substitute pass from unit tests.

## Validation

Independent source review completed; cancellation/late-response and concrete-locale
findings were fixed before the full suite. No source changes followed that test run.
The coordinator also reviewed the offline adapter against the exact pinned dependency.

Full suite: **754 discovered, 739 passed, 15 opt-in skips, zero failures**, exit 0,
completed 2026-09-10 16:50:30 Europe/Oslo in 38.902 seconds. All 22 new tests passed:
11 coordinate-resolution, eight queue/cache/cancellation, three real bundled-database
adapter tests (Oslo, Tokyo country localization, ocean and distance thresholds).

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Environment: arm64 macOS 27.0 (26A428), Xcode 26.6 (17F113), development app 2.9.2 (37).
Installed stable copy unchanged. The working source contained only this slice's new
files and generated project at test time; checklist/report edits are documentation.

- Log: `build/m2-geocoding-foundation/full-tests.log`
- SHA-256: `20c0dd4e2a5d383d28e4cedc37c07127538a0cf1256f32032710bdca9a2f6b38`
- xcresult: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.10_16-49-37-+0200.xcresult`

Candidate remains unfrozen and all affected manual checklist cases remain unrun.
The checklist now includes the RAW existing-sidecar/no-GPS regression and makes clear
that standalone provider code is insufficient for the offline UI workflow. Human
results are absent and untouched. This does not complete M2 or supported-OS evidence.
