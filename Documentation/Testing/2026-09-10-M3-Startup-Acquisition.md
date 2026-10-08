# Paused runtime construction and immutable legacy acquisition

Development checkpoint, 2026-09-10. Normal app startup still uses the legacy path.
This does not enable 3.0 templates or complete migration, M3 or candidate readiness.
The installed stable app and personal configuration were not modified.

## Paused AppStore construction

`AppStore.makePausedForValidatedStorage` constructs all eight repository dependencies
from one explicit v3 layout, including the default sync engine and job reset service.
The caller must first admit the complete store set and hold writer exclusion.
The factory itself strictly reads the six AppStore JSON libraries before any
AppStore/scheduler exists. Missing, corrupt, future, individually recovered backup,
duplicate-identity or unresolved-server-reference inputs throw; no partial empty
state escapes. The strict path does not perform legacy embedded-server migrations,
photographer merges or startup saves.

Runtime jobs begin disabled while retaining their configured launch preferences,
and the factory skips scheduler restart. Calendar construction, lifetime ownership,
recovery UI and the eventual decision to start jobs remain bootstrap responsibilities.
No production call selects this factory yet. This API is paused construction from
an already-admitted root, not an alternative full-store validator.

Retained credential IDs are forwarded into the store's persistence coordinator.
When a retained backup has unknown credential reachability, the driver can disable
obsolete-credential garbage collection entirely. That policy never disables cleanup
of newly staged credentials after a failed save. Tests use fake Keychain and login
services, preserve all input bytes at construction, and exercise actual paused
AppStore saves with both retained-ID and unknown-reachability policies.

## Immutable SQLite acquisition before repository construction

`LegacySignatureSQLiteAcquisition` reads bounded original main/WAL/optional SHM
files through read-only descriptors, retaining exact bytes and identity/hash
provenance. It copies main and WAL together into a unique private stage before
SQLite opens them. A pinned read-only transaction plus SQLite backup produces a
standalone v2 snapshot including committed WAL evidence. Original SQLite files are
never opened by SQLite, checkpointed, repaired or written; original bytes and
companion presence are rechecked before return. SHM reconstruction/coordination
occurs only in the private stage. Missing original SHM is supported.

A clean captured main without a WAL uses immutable read-only access to the private
copy, avoiding SQLite's attempt to create WAL coordination on an ordinary read-only
open. WAL-present copies use normal read-only access so committed WAL frames remain
visible. Rollback journals, unsafe files/ancestors, unknown schemas, corrupt/truncated
or stale WAL tails and limit/deadline failures require explicit recovery. Limits
bound source/output bytes, records, user-space hashing and SQLite work; kernel I/O
cannot be promised a hard wall-clock deadline. Converter row validation remains
separate. Returned original captures must be retained by the future migration driver.

## Bounded older schedule conversion

The JSON conversion adapter can materialize missing/null photographer tracks only
when given a caller-frozen Calendar. It preserves clip/day order and deduplicates
tracks using the legacy model, with explicit calendar/timezone provenance and a
shared maximum of 50,000 day iterations across the selected stores. Absolute input
dates must be finite and within Gregorian years 1..<10000 with positive duration.
No calendar or timezone is silently taken from the current Mac.

Only known job automation and shared calendar document paths are eligible; unknown
extension objects resembling clips remain untouched. Raw byte-span patches insert
or replace only the track member, preserving unrelated strings, unknown members,
scalar encodings and original source hashes. Explicit tracks remain unchanged.
Ambiguous duplicate members on interpreted paths fail rather than choose a different
payload from the app decoder. Inference occurs before domain decoding, avoiding the
old decoder's unbounded implicit loop. The default without an explicit Calendar
continues to reject implicit nonempty tracks.

Independent review caught an overly broad traversal that could rewrite unknown
clip-shaped extension data; the implementation was narrowed to actual model paths.
The coordinator also corrected a new test fixture to valid remote-to-local jobs
before running the suite. Those are development findings, not production incidents.

## Validation

App-code commit: `689e73e`. Integration ran from `a94cf3e` with the eight reviewed
code/test/project files modified, then saved those exact files without further
changes. All three slices received independent review. Tests used macOS 27.0
(26A428), arm64, Xcode 26.6, development version 2.9.2 (37).

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

The first build found a Swift exclusive-access error in a new track test's nested
optional mutation. Capturing its start date in a local constant fixed the fixture;
no application behavior changed. That initial build exited 65 before tests and is
retained at `build/m3-startup-acquisition/initial-build.log`.

The final full suite exited **0** at **14:04:15 Oslo**: **658 discovered, 643 passed,
15 opt-in skips, zero failures**, 22.239 seconds. This includes 22 new cases: six
strict startup/credential tests, eight original-byte-safe SQLite acquisition tests,
and eight frozen-calendar adapter tests. Missing opt-in prerequisites remain unrun.

- Log: `build/m3-startup-acquisition/full-tests.log`
- SHA-256: `2890172482674b4f69cb147e974f8201c68b4d946562f2fc373a5963b3d57bb4`
- xcresult: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.10_14-03-46-+0200.xcresult`
- Development app: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Build/Products/Debug/AagedalFTPSync.app`

An independent copied-source SQLite harness also passed 41 tests with no warnings
(8 acquisition plus 33 prior cases). The app-linked full suite above is primary
evidence. Unchanged template package/long benchmarks were not rerun. This unsigned
development verification is not signed-candidate or actual GUI evidence.

## Remaining driver and acceptance gates

- Assemble explicit primary/backup selection and complete recursive inventory,
  retained-source provenance and credential reachability under all-writer exclusion.
- Feed the acquired original main/WAL/SHM captures and standalone snapshot into the
  migration transaction together. The generic migration helper still rejects SQLite
  companions; do not evade that guard by omitting WAL or by unrelated recapture.
- Validate complete initial/current v3 stores, then gate AppStore and calendar
  construction behind loading/ready/recovery state. Calendar events, pending receive
  and original launch preferences must follow the explicit recovery/start policy.
- Coordinate v3 lifetime ownership and exclusion of already-shipped older binaries.
  Wire registry provisioning before new-map transfers and retain fail-closed store
  behavior; a paused constructor alone does not finish those runtime requirements.
- Activate variable persistence/configuration/calendar capability negotiation and
  processing UI only after the storage boundary is ready. M0/M2/M4–M6 checks remain.

No GUI pass is claimed. Native selection previously stalled for 5,897 seconds
against a 20-second timeout, and another app coordinator remains active. This cycle
uses independent implementation/test work rather than repeat that unchanged call.
Human checklist results remain absent and were not populated or altered.
