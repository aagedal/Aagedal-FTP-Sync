# Strict store admission and legacy IPTC encoding

Started from clean `e166b64`; implementation committed as `3970874` on
`codex/version-3-0-plan`. Status remains **IMPLEMENTING**. No production v3 root,
candidate or completed milestone is claimed. Human checklist results remain
absent and untouched; the ten-minute coordinator remains active, with zero
consecutive cycles without substantive progress.

## Changes and boundaries

Opt-in v3 source-signature storage now requires an existing SQLite file with
application ID `0x41465333` (AFS3), user version 3 and the canonical table/index
definitions. Read-only admission inspects committed WAL state before opening a
non-creating read/write handle; that handle is revalidated before write PRAGMAs.
Missing, corrupt, legacy, future or incompatible stores are not migrated, repaired
or replaced. Inspection bounds metadata size and execution time. SQLite may
maintain its coordination SHM file; rejected main/WAL bytes are preserved. Legacy
default behavior remains unchanged, and snapshots retain the selected schema.

`version3InitializationSQL` is a converter contract for a newly created, owned
migration stage. It is not a runtime upgrade command. Schema admission deliberately
accepts only the canonical ASCII token sequence, ignoring casing/spacing. The
directory and companions must be trusted/stable, with other writers excluded for
the actor's entire lifetime; cached handles do not detect external replacement.

Normal and replacement download name maps now have separate v3 envelopes bound
to the actual mapping filename. Replacement dates must be finite and associated
with saved names. Active sessions check file identity even before clean export
and source-removal checkpoints. Missing, future, swapped or changed maps block
the delegated operation. SyncEngine propagates the manifest's selected format;
legacy mappings retain their existing flat/replace JSON behavior.

An explicit initializer can exclusively publish a new empty map using a private
0600 temporary file, atomic rename and fsync. A future durable registry/lifecycle
must authorize that identity as genuinely new and register it before transfers.
Ordinary sessions never infer newness from missing files and never provision v3
maps. Production v3 selection remains disabled until this lifecycle is integrated.

Embedded metadata writes now perform the pinned library's existing UTF-8
conversion before applying new text. Previously a new Unicode value could fail
when the setter tried to encode it in an existing Latin-1/Windows-1252 character
set, even though final serialization always emitted UTF-8. Existing text is
decoded and re-encoded, never merely relabeled. Known binary datasets, repeated
values and field policies are preserved; undecodable legacy input fails before
file writing. Unknown-tag interpretation remains the pinned library's behavior.
RAW sidecar writing and legacy scheduling are unchanged.

## Validation

Full app suite on the source subsequently committed unchanged as `3970874`:
**590 discovered, 575 passed, 15 opt-in skips, zero failures**, exit 0 at
12:37:37 Europe/Oslo, 20.053 seconds of test execution. New cases comprise 11 strict
SQLite, nine naming and four encoding tests. The actual JPEG fixtures inject raw
legacy IIM records, verify detected character sets and retained values, compare
decoded pixels and compressed scan bytes, and check canonical charset output.
The SQLite cases include real WAL-only schema changes and main/WAL preservation.

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Log: `build/m1-store-lifecycle/full-tests.log`, SHA-256
`c91743fea0d841384c72f1a1bfb94fe9d86ce6b054b586e8a8e66b8c22141744`.
Result bundle: Xcode DerivedData
`Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.10_12-37-02-+0200.xcresult`.
Host remains macOS 27.0 build 26A428, Apple silicon, Xcode 26.6 build 17F113.
Development app remains 2.9.2 (37), at that DerivedData folder's
`Build/Products/Debug/AagedalFTPSync.app`; installed stable app is unchanged.
The unchanged 33-test template package result is retained from `c0de968`.

Independent review resolved SQL token-boundary and non-ASCII whitespace mistakes
that could otherwise accept weaker nullable-column schemas. It then approved the
final SQLite/naming/encoding changes and tests. The SQLite agent also passed a
20-test copied-source harness with dependency stubs; the full app suite above is
the integration evidence. No model, remote transport or supported-OS gate is
substituted by this run.

## Computer testing attempt

Retried actual computer testing after inventorying other active tasks. CUA surface
inventory succeeded in 0.19 seconds. An isolated development launch used existing
UITestSupport with session `coordinator-20260910-storage`, disabled synthetic job,
temporary repositories and fake endpoint credentials. The launched binary was
the prior `c0de968` development build, not this new implementation. No normal
jobs or installed app were intentionally opened. Launch metadata/log are in
ignored `build/m1-store-lifecycle/gui-launch.*`.

Selecting that exact app path through `cua.getApp` returned computer-server error
`-10005 timeoutReached` after **5897.51 seconds**, despite `timeout_ms: 20000`.
No app screen, workflow or successful launch was observed. The recorded fixture
PID was absent when checked afterward, so no process was killed. This repeats the
earlier native-tool stall and remains an unresolved computer-testing limitation;
no GUI checklist pass is recorded. Avoid another unbounded native selection in
the same run; revisit tool availability and a bounded isolated launch on a later
cycle while continuing implementation independently.

## Next actions

1. Implement a read-only cross-store converter/validator, complete recursive
   inventory and retained credential reference extraction. Add the new-map registry
   and lifecycle, then select one validated v3 root before normal repositories
   start. Hold writer exclusion across snapshot/migration and repository lifetime.
   Include endpoint and calendar device credentials and explicit recovery UX.
2. Persist complete activation/source values and independent processing settings,
   with configuration/calendar capability rejection before old clients could see
   activated source. Integrate strict per-image context, asynchronous preview and
   transfer/reprocess paths; add partial audit and source-removal guards first.
3. Continue remaining providers, model/library contracts, measured performance,
   supported-OS and actual computer checks from the complete plan. All final
   agent checklist cases and human acceptance remain outstanding.
