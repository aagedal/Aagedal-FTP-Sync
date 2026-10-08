# M3 migration intent persistence

Implemented and reviewed locally at `38a3fbc`, based on `73fbd7a`, on
`codex/version-3-0-plan`. This is a persistence foundation, not an available
calendar conversion workflow or a release candidate.

## Behavior and boundaries

- Extracted calendar state/repository definitions from the coordinator. Existing
  legacy payloads omit the new optional journal key and retain their JSON shape.
- Added immutable versioned migration intents that retain the full unchanged
  literal legacy baseline, account/job identity, canonical endpoint and one new
  destination UUID. Initial scope is a conflict-free, unrestricted owner snapshot.
  Unsynced local edit review remains the future caller's responsibility.
- A prepared intent never claims a request was unsent. Recovery must fetch the same
  destination UUID. Confirmation requires the exact new namespace, owner role,
  revision 1, document, name and time zone. A model-level committed receipt retains
  old provenance, but production persistence deliberately rejects that phase until
  namespace-aware binding orchestration is implemented.
- Version3 calendar storage admits prepared and server-confirmed journals while
  freezing their source binding and endpoint. Explicit transitions require the exact
  prior persisted journal array, preserve identities and cannot remove or reverse
  receipts. Beginning also compares the source against the current disk baseline.
  Ordinary saves cannot begin, advance, replace or discard a journal.
- A persistent v3-only lock serializes cooperating writers around reread/compare/
  atomic replacement. Contention fails immediately for retry. Legacy saves create
  no lock artifact, preserving strict legacy migration inventories.
- Journal-key presence, including empty/null/malformed values, is recovery-sensitive.
  Legacy storage rejects it before domain decoding; malformed earlier siblings cannot
  conceal a journal and allow a stale save to overwrite it. Duplicate destinations
  and affected jobs, endpoint changes and altered source bindings are rejected.
- Current coordinator legacy admission rejects pending migrations before live
  requests. There is no UI or production call that initiates a journal yet. No live
  v3 binding, template activation, rebind, invitation or creation action was enabled.

## Verification

macOS 27.0 build 26A428, arm64, installed Xcode toolchain. Debug app remains
2.9.2 (37), `CODE_SIGNING_ALLOWED=NO`, at
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Build/Products/Debug/AagedalFTPSync.app`.
Disposable temporary directories and synthetic literal calendars only; no user data,
keys or server endpoints accessed. Tests ran against the owned dirty changes later
committed unchanged at `38a3fbc`; the storage test file and its generated project entry
were added after the broad run, then separately compiled and executed.

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
# After adding the storage regression file:
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -only-testing:AagedalFTPSyncTests/MetadataCalendarMigrationStorageTests
```

Broad run: exit 0, **970 discovered, 955 passed, 15 opt-in skips, zero failures**,
50.577 seconds, completed 2026-09-11 20:05:13 +0200. Includes six new journal-model
cases. Log `build/m3-migration-journal/full-tests.log`, SHA-256
`99c4c777cf794c3d2593cae3b429d52c33a136bf4d42007a7efb9f97658bd625`.
xcresult: `Test-AagedalFTPSync-2026.09.11_20-04-12-+0200.xcresult` beneath the
DerivedData directory above, `Logs/Test/`.

Storage run: exit 0, **11 passed, zero failures/skips**, 0.191 seconds, completed
2026-09-11 20:05:54 +0200. Log `build/m3-migration-journal/storage-tests.log`, SHA-256
`07049b1c1719ec3f0a8d6b25b476ff9b6d23b1ca5c02a7b6c3f8479dff04db5e`.
xcresult: `Test-AagedalFTPSync-2026.09.11_20-05-50-+0200.xcresult` in the same
`Logs/Test/`. The 11 storage tests were not part of the earlier 970-test broad run.
No app-source changes followed that broad run.

Independent agent review covered storage identities, corrupted-record recovery,
CAS/locking, phase transitions and migration inventories. It found that applying
new locks to legacy saves would introduce an undeclared legacy inventory artifact;
root restricted locks to v3 before tests. A specific regression now verifies this.
A separate agent supplied the storage regression suite. Root integrated, inspected
the diff and ran builds serially. `git diff --check` passed. No failed test run.

No fresh native app/UI test was claimed: the companion task was active in desktop
work and the previously changed isolated native observation path still has an
unresolved selection/authentication gate. No new controls exist in this slice.
Unchanged PHP/MariaDB and native probe suites were not repeated. Their prior evidence
remains in the protocol-foundation and Apple-integration reports. Supported-OS,
manual workflows and signing evidence remain open. Human checklist results remain
absent and untouched; no agent manual case was marked passed.

## Next implementation

1. Add immutable namespace-aware bindings, conflict/cache and receive journals, then
   route coordinator requests, discovery and invitations explicitly by protocol.
2. Implement capability-checked, unsynced-edit-reviewed explicit creation and recovery:
   persist prepared intent before sending, recover uncertain responses with the same
   UUID, persist confirmed result, atomically rebind and retain old provenance. Add
   interruption, lost response, stale local edit and endpoint-change tests.
3. Lift activation only for confirmed v3 bindings, with explicit deactivation receipts
   and a user-facing new-calendar explanation. Keep old calendars separate and issue
   fresh invitations. Observe the resulting workflow on an authorized desktop.

Useful implementation progressed; blocked-cycle counter remains zero. No push,
release, production deployment or installed-app replacement occurred.
