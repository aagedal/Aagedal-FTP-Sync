# Frozen-store conversion and mapping registration

Started from clean `2d0dcc8`; reviewed implementation committed as `057cdc0` on
`codex/version-3-0-plan`. Status remains **IMPLEMENTING**. These are opt-in
conversion/lifecycle components, not enabled startup migration. Human checklist
results remain absent and untouched. The coordinator remains active with zero
consecutive cycles lacking substantive progress.

## Implemented

`Version3JSONStoreConversion` accepts an explicitly selected immutable set of the
nine canonical legacy JSON primaries. It emits complete v3 envelopes, selected
source hashes, absent-store initialization counts, reference diagnostics, pending
receipt phase and reachable credential IDs. It never opens repositories, selects
backups, reads Keychain or writes app data. Present payload bytes are preserved
inside the envelope, retaining literal braces, optional/default fields, dates and
unknown fields; unknown semantics are not claimed to be understood.

Live references and duplicate identities are checked. Historical audit, failure,
event and ownership records are retained even after their jobs disappear. A
calendar binding to a deleted job is likewise an existing recoverable state and
is reported, not discarded. Pending calendar receipts must match either their
before-installation or exactly installed job state. Credential reachability covers
the selected records only: retained backups require a separate union before any
garbage collection is enabled.

Stable encoder output is BOM-free UTF-8. Other encodings are refused instead of
silently changing selected bytes. A preflight using the same keyed JSON decoder
as the models prevents duplicate-key interpretation from bypassing checks. Older
nonempty calendars lacking explicit photographer tracks currently require
reconciliation: their existing decoder can infer days using Calendar.current,
including unbounded iteration on damaged date ranges. No implicit inference or
timezone-dependent defaults are materialized by this converter. Supporting these
older inputs safely remains an integration gate.

`Version3SignatureConversion` takes explicit absence or immutable standalone v2
SQLite snapshot bytes and returns canonical v3 bytes, count and historical job
IDs. A private stage under an existing trusted directory is the only filesystem
mutation. Input/output bytes, rows, text fields and SQLite execution are bounded;
failed stages are cleaned up. UUID/source-key/path/numeric values are validated
and exact SQLite values are bound into the new store. Main-file bytes from live
WAL databases are not acceptable substitutes for the repository snapshot API.
Only canonical optional v2 `sqlite_stat1` statistics are admitted, then discarded
as derived data; the new v3 schema remains the exact table/index pair.

`DownloadNameMappingRegistry` now supplies the durable distinction between new
and lost mapping receipts. Under a cooperating process lock, it records PREPARED
before exclusive map creation and COMMITTED only after validating the exact empty
map. Interruptions resume that prepared identity. Missing committed maps, orphan
unregistered maps and nonempty prepared maps fail for explicit recovery. Registry
updates and new-map publication are atomic and synchronized. Existing registry
and mapping reads validate identity, bounds and schemas; malformed/future stores
cannot authorize provisioning. No runtime caller selects this API yet.

Its pure legacy-directory converter emits both map modes and the complete initial
registry, preserving alias values and replacement dates. Filenames must be the
canonical lowercase digest plus `.json` or `.json.replace`; path association and
mode-specific constraints match the naming session. All selected maps must be
inventoried, not inferred from today's live jobs.

## Verification

Full app suite on the uncommitted source subsequently saved unchanged as `057cdc0`:
**618 discovered, 603 passed, 15 opt-in skips, zero failures**; exit 0 at 13:04:52
Europe/Oslo, 17.176 seconds of test execution. The 28 new tests comprise ten JSON
conversion, nine SQLite conversion and nine registry/conversion cases.

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Log: `build/m1-conversion-registry/full-tests.log`, SHA-256
`4c09e7415f728eae3b784bb1f433e1b2de9972ec840832cacec7a2d1715c97f6`.
Xcode result bundle under DerivedData
`Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/`:
`Test-AagedalFTPSync-2026.09.10_13-04-29-+0200.xcresult`.
Host: Apple silicon, macOS 27.0 build 26A428, Xcode 26.6 build 17F113. Development
2.9.2 (37) remains at that DerivedData folder's `Build/Products/Debug/AagedalFTPSync.app`;
installed stable is unchanged. The unchanged template package's 33-test result
remains recorded at `c0de968`.

Independent review resolved payload reencoding/default inference, duplicate-key
preflight and byte-encoding hazards, valid backslash versus invalid newline paths,
legitimate engine-generated statistics and a nondeterministic test byte assertion.
The isolated registry harness also caught Foundation rewriting an existing
`/private/tmp` URL to the `/tmp` alias during standardization; actual ancestor
validation now handles the physical directory while still refusing symlinks.
The final nine registry tests passed in a copied-source harness before integration.
The SQLite agent's copied-source/stub harness passed 29 tests; full app evidence
above supersedes that narrower integration context.

The first full run passed before the legitimate statistics fixture was added;
the final run includes that correction. Native computer selection was not retried
against the unchanged failure from the preceding cycle (5897-second tool timeout).
No new GUI, supported-OS or final checklist evidence is claimed.

## Next integration work

1. Assemble a complete migration driver with explicit source/backup selection,
   consistent recursive inventory, writer exclusion, v1-JSON signature handling,
   older implicit-track reconciliation and retained-backup credential union.
   Combine the three adapters with full output validation before root selection.
2. Extend committed-open validation for dynamic maps. The immutable installation
   manifest currently supplies only its original file set to the validator.
   Preserve that manifest as provenance; separately collect all currently
   registered maps under exclusion, handle prepared entries explicitly, reject
   orphan files and align resource budgets (primitive default 512 files versus
   registry limit 4096). Initial PREPARED installation must retain exact hash checks.
3. Wire registry admission and credential protection into the validated v3
   lifecycle, then implement explicit recovery UI. Do not enable activated templates
   against legacy roots or incompletely migrated stores.
4. Integrate source/activation persistence, independent policies, asynchronous
   preview/context, partial audit/source-removal guards and configuration/calendar
   capability boundaries, then continue all remaining M0–M6 acceptance work.
