# Current v3 storage admission and older signature conversion

Development checkpoint on 2026-09-10; M3 and candidate readiness remain incomplete.
The installed 2.9.2 app and personal stores were not changed. This slice remains
opt-in and does not switch production startup to v3.

## Changes and reviewed behavior

`VersionedAppStorage` now accepts a pure `currentStorePaths` resolver on committed
opens. The resolver sees current bytes of the initial manifest's stores, allowing
it to derive required runtime maps from the mutable registry. The helper unions
those paths with the initial required set, safely reads every addition, applies
aggregate count/byte limits, rejects SQLite companions, and rechecks collected
identities and bytes before final validation. It never rewrites the immutable
migration manifest. PREPARED validation and recovery still require the exact
initial hashes and never invoke the current resolver.

The default file budget is now 8,192, accommodating 4,096 name maps plus fixed
stores and retained source paths. Each source/output set still has a 256 MiB data
budget. The independently bounded manifest budget is 32 MiB, allowing two large
sets of path/hash entries. A test actually creates and opens 4,096 additional
files; this verifies count admission, not a production performance budget.

`DownloadNameMappingRegistry` provides a concrete pure resolver and full map
validator. Its lock-held `withValidatedCurrentMappings` performs a bounded actual
flat-directory inventory, reads all current maps, and rejects missing, orphaned,
future, malformed, mismatched, linked or prepared receipts. It supplies exact
registry/map bytes to a synchronous admission callback. The integrated test opens
`VersionedAppStorage` inside that callback, compares the complete collected set,
and verifies that runtime mappings never change the original manifest.

The registry lock excludes cooperating provisioners only. The future driver must
also exclude naming-session and other repository writers throughout admission.
Prepared registration requires explicit recovery before normal startup; inspection
never silently initializes it. An absent map directory is valid for an empty
registry. First authorized provisioning creates and synchronizes that directory,
but refuses to recreate a directory containing any committed receipt identities.

`Version3SignatureConversion.Input.legacyJSON` accepts explicitly selected immutable
v1 JSON and a caller-frozen migration date. It preserves stored source identity,
legacy millisecond date decoding, historical job references, and valid last-record
wins deduplication using Swift's original UUID/string equality. Every input record
is bounded and validated before deduplication, so a later valid duplicate cannot
hide damaged earlier input. Malformed present JSON never becomes an empty store.
The explicit empty array remains valid. This uses the same private canonical v3
SQLite output path and resource controls as the existing v2 converter; it never
chooses or rewrites a legacy primary or backup.

Independent review covered all three components and their tests. New checks cover
current inventory and immutable-manifest separation, lost/orphan/corrupt maps,
prepared journals, provisioning locks, absent directories, future registries,
path/link/count/byte limits, source mutation during collection, v1 Unicode identity,
large integer sizes, negative-epoch millisecond dates and malformed inputs.

## Validation

App-code commit: `3d62862`, reviewed and saved after verification. The working
source was based on `057cdc0` (documentation HEAD `6952fc0`) with the six reviewed
code/test files modified; no unrelated code was staged. macOS 27.0 (26A428), arm64,
Xcode 26.6 / existing development app version 2.9.2 (37).

Commands (coordinator alone, signing disabled for development tests):

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO \
  -only-testing:AagedalFTPSyncTests/Version3SignatureConversionTests
```

- Full suite exited 0 at 13:30:25 Oslo: **636 discovered, 621 passed, 15 opt-in
  skips, zero failures**, 23.367 seconds. This includes 18 new cases: eight generic
  current-collection tests, six registry/admission tests and four v1 JSON tests.
  Log: `build/m3-current-storage/full-tests.log`, SHA-256
  `50b0020fac4edec9c8a855da7337fcb203b2294ac0e3f5585acb2ba43d007015`.
  xcresult: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.10_13-29-54-+0200.xcresult`.
- That build exposed a concurrency conformance warning in the decoder's userInfo
  context. The final change explicitly marks the immutable deadline class and
  decoding context Sendable, with no unchecked conformance or behavioral change.
  The final rebuild and affected converter suite exited 0 at 13:31:53 Oslo:
  **13 passed, zero failures/skips**. The warning is gone. Full behavioral coverage
  above precedes only these two conformance declarations.
  Log: `build/m3-current-storage/final-converter-tests.log`, SHA-256
  `1a61603ec7a47cb744da077076b03fb0a3c95c86575e23e8d4548ed15efeba3f`.
  xcresult: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.10_13-31-49-+0200.xcresult`.
- An independent copied-source SQLite harness passed 33 tests after the same
  conformance-only fix, with no warnings. Full app-linked results above are the primary evidence.
  Unchanged template package and long benchmarks were not rerun.
- Development app build path remains
  `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Build/Products/Debug/AagedalFTPSync.app`.
  This is not a signed release candidate or GUI evidence. No project regeneration
  was needed because this slice modifies existing project-linked files.

## Startup integration gates resolved by inspection

Normal `AagedalFTPSyncApp.init` constructs `AppStore` immediately. Its initializer
loads and can rewrite embedded server profiles/photographers, then starts the
scheduler. Calendar construction defaults separately to legacy storage and its
start method begins polling and observers. A late validation call is insufficient.
The next driver must gate both constructions behind loading/ready/recovery state,
then inject one validated layout, retained credential policy and recovery flags
into every repository, sync engine and calendar coordinator before enabling work.
Current load failure paths can appear as empty collections and then save inferred
state; production v3 admission must fail closed rather than enter that path.

The driver must explicitly inventory/select related primaries and backups under
writer exclusion, retain every source, and union credential references across all
retained copies (including calendar device IDs and pending receipts). An unreadable
retained backup cannot mean an empty credential reference set: disable credential
collection or require recovery when reachability is uncertain. `AppStore` still
needs to forward this policy into its persistence coordinator.

The existing SQLite snapshot method is on an already-open repository. Constructing
that legacy repository may run PRAGMAs, create schema or migrate JSON before the
snapshot call. It cannot be used unchanged for immutable pre-constructor source
acquisition. Add a dedicated read-only acquisition adapter or explicitly require
a closed standalone source; never drop committed WAL data or silently copy only
the main file. A cooperative v3 lifetime lock cannot stop shipped 2.9 binaries;
cross-version writer exclusion remains an explicit startup requirement.

Older schedules requiring implicit photographer-track inference still need the
frozen-zone conversion adapter. Neither these remaining gates nor activated UI,
OS/model/server validation can be counted as passed by this storage checkpoint.
No desktop pass is claimed: native app selection previously stalled for 5,897
seconds despite a 20-second timeout, and other app coordinators are active. This
cycle performs independent implementation/testing without repeating that unchanged
native call. Human checklist results are absent and were not created or modified.
