# M1 per-image processing integration — 2026-09-11

Implementation commit: `acce909`, following baseline `32321f0`. This checkpoint integrates activated local templates into
preview, transfer and explicit reprocessing. It is not a release candidate.

## Behavior and boundaries

Jobs persist a concrete processing time zone when activation is explicitly saved.
Legacy jobs retain absent zones and literal behavior. Decoding never samples the
current zone; malformed persisted zones cannot silently recover older configuration
or be overwritten through stale saves. Profile save/import also validates linked jobs.
Active execution requires a valid saved zone before opening transfer endpoints.

Per-image preparation shares writable-field decisions with the writer, freezes the
processing date separately from legacy arrival scheduling, and reads strict original
capture metadata only for writable fields that need it. Explicit capture offsets win;
offset-free originals use the persisted zone. RAW sidecar capture fallback applies
only when embedded capture is unavailable, never when it is invalid or ambiguous.
Missing capture, location or person dependencies omit entire fields or keyword lists.
Geocoding and face services are not connected by this slice.

Preview remains read-only and exposes proposed values, preserved fields and omission
reasons. Preparation failures are per-file; cancellation propagates to the detached
worker. Transfer retries retain the frozen operation date. Incomplete enrichment is
audited as failed and cannot authorize processed-source removal. An active resolution
with no proposed fields does not invoke the writer or create an empty RAW sidecar.
Audit evidence records context and typed outcomes without storing resolved text,
coordinates, credentials or template sources in the new evidence object.

Activated reprocessing publishes only against immutable originals. Local publication
holds originals by exclusive rename, compares full bytes, publishes outputs only into
absent paths, and rechecks original/output bytes before commit. Guard-only RAW images
return with the same inode and modification date. Conflicting output edits are retained;
failed restoration leaves an explicit recovery directory instead of overwriting another
writer's replacement. This is not filesystem isolation from an external writer that
already holds an open file descriptor, and is not crash-atomic group publication.
It assumes stable parent paths and immutable caller staging. Unsupported endpoint
implementations fail closed.

The standalone photographer-list format remains literal-only v1: active copyright
requires configuration package 3. Both envelope and raw-array legacy imports preflight
markers, preventing accidental activation loss through the older list route.

## Verification

Independent reviews covered job Codable parity/recovery guards, per-image policy,
preview/transfer/reprocess semantics, audit evidence and matching publication. Review
fixes restored post-download arrival scheduling, caught preparation per file, avoided
empty sidecars and initialized zones when linked profiles change. A failable audit
initializer now uses flatMap.

The first compile found existing trailing closures binding to the newly inserted clock
parameter; parameter ordering now preserves the original session-factory calls. The
first full run reached all 834 tests; one concurrency fixture failed three assertions
because reprocessing creates a concrete local session and bypassed its general session
factory. A narrow local-session factory now enables an asserted real transaction hook;
the default production local-only behavior stays the same. Failed logs are retained.

Final full suite: **835 discovered, 820 passed, 15 opt-in skips, zero failures**,
exit 0 at 2026-09-11 10:09:22 Europe/Oslo, 42.860 seconds. The 41 new tests cover
8 zone/recovery groups, 7 per-image groups, 5 audit groups, 5 standalone library
boundaries, 7 matching-publication groups, 3 preview groups and 6 integration groups.
No application source changes followed the successful run.

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Environment: Xcode 26.6 (17F113), arm64 macOS 27.0 (26A428), development app 2.9.2 (37).
Tested dirty state contained this source/project/test slice and its documentation.

- Log: `build/m1-per-image/full-tests.log`
- SHA-256: `156afe58fd87712cc77cc581e64a8f3be1474e06f8f7f9d137dd4bd6dba9aa09`
- xcresult: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.11_10-08-32-+0200.xcresult`

The pending read-only task inventory call was stopped after it failed to return.
No shared-desktop operation was attempted. Human result file remains absent.
No native GUI observation or human checklist result is claimed by this checkpoint.
The previous native accessibility selection timeout remains unresolved; this run does
not repeat an unchanged selection attempt. Installed stable 2.9.2 is unchanged.

Variable insertion/editor activation, geocoding settings, face matching, protocol3
sharing, real-camera RAW fixtures, supported-OS execution and candidate checks remain
open. Passing unit tests do not complete M1 or replace actual app manual testing.
