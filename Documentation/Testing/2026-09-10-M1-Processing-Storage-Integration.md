# Processing and storage integration checkpoint

Recorded 2026-09-10. Started from clean `1f3ad35`; reviewed implementation committed
as `61aea96` on `codex/version-3-0-plan`. Status remains **IMPLEMENTING**. No candidate
identity, user acceptance or completed milestone is claimed. Human checklist results
were absent and were not populated. The ten-minute automation remains active, with
zero consecutive cycles lacking substantive progress.

## Changes

The app now links the local `MetadataTemplates` package. Its pure
`MetadataProcessingCoordinator` accepts immutable source/activation values and a
frozen variable context, reports per-field proposed/preserved/omitted outcomes,
and produces one immutable writer input. Dependency discovery excludes fields the
caller has determined will be preserved. The matched photographer's canonical
name overrides an unrelated sample name in the supplied context.

Activated results observe the pinned IPTC byte limits (Headline 256, Description
2000, Copyright 128, each Keyword 64) consistently for embedded and sidecar
destinations. Invalid XML characters and unavailable/oversized results omit the
entire affected field; an unavailable keyword member omits the whole keyword list.
Legacy values retain their earlier literal, normalization and over-spec writer
behavior. Independent review caught an explicit literal keyword override that
bypassed normalization; it was fixed and covered before validation.

Existing preview, transfer (including the shared early-delivery path) and reprocess
paths now prepare a literal snapshot once per item. Reprocess shares it between
assessment and writing. Transfer retains its existing write-attempt and fallback
behavior. **Production paths do not yet call activated resolution**: per-image
context reading, persistent markers, UI and source-removal completion guards must
be integrated first. `resolutionComplete` only describes resolution, never proof
of successful writing, provider work or publication.

`AppStorageLayout` centralizes all current store names beneath an injected root.
Repository defaults still use Foundation's sandbox-aware legacy Application
Support location; explicit file overrides still take precedence. Calendar events
and download name mappings remain siblings of the selected repository files.
Constructing a layout neither creates directories nor selects/migrates v3 storage.

The source-signature actor has an opt-in SQLite backup API for an already-open
database. A read transaction pins committed WAL data; a bounded incremental backup
is validated, closed, synchronized and exclusively published from private staging.
It rejects existing outputs/companions, unsafe directory paths, wrong schemas and
resource limits. Independent review found no blocking source/cleanup issue under
the documented trusted, stable directory assumption. No production migration or
backup scheduling calls the new API.

## Verification

Full app suite: **535 discovered, 520 passed, 15 opt-in skips, zero failures**.
Exit 0 at 10:08:28 Europe/Oslo, 16.328 seconds of test execution, using:

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

This includes eight processing tests, five layout tests and nine snapshot tests,
plus existing metadata, RAW sidecar, transfer, source-removal and recovery cases.
The snapshot test uses a real temporary SQLite WAL and a second connection's
committed change, verifies both source main/WAL bytes remain identical, validates
the standalone output and proves subsequent source writes remain independent.
Cancellation and tiny-deadline tests cover rejection before work. Byte/schema
failure cases cover cleanup after private staging exists; cancellation/deadline
expiry during a substantial in-flight backup remains untested.

The snapshot agent also passed nine isolated tests (production repository copied
with dependency stubs); the full app run above supersedes that limited harness
for integration. The package's unchanged 29-test pure suite is recorded in the
earlier checkpoint and was not redundantly rerun.

Host: macOS 27.0 build 26A428, Xcode 26.6 build 17F113; app remains development
2.9.2 (37), unsigned test build in DerivedData. No installed app was replaced.
Log: ignored `build/m1-processing-storage/full-tests.log`, SHA-256
`6c3496d23614a912cb9534f2209f3a67ec6f6b01099a0e8328d91e577e458e0c`.
Result bundle:
`~/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.10_10-07-57-+0200.xcresult`.

Desktop testing was deferred: Photo Agent and both media-app coordinators were
active on the shared desktop at the start of this cycle, and the previous read-only
computer call had stalled for hours. No new feature UI was enabled. No GUI or
supported-OS case receives passing evidence from this unit run; revisit serialized
desktop availability when testing the integrated UI.

## Next gates

1. Implement versioned store adapters and cross-reference validation, then a startup
   lifecycle selecting one validated layout before normal writers open. Preserve
   credentials reachable from retained 2.9 stores and add explicit recovery UI.
   The new snapshot API refuses unopened repositories; ordinary source-signature
   initialization still has legacy migration/schema side effects. Inspect schema
   before that initialization in the future migration driver. SQLite snapshotting
   alone does not establish consistency across jobs/calendar/ownership stores.
2. Before active tokens reach transfer: add a strict EXIF original-date decoder with
   offset provenance and persisted job zone, plus partial-completion audit/removal
   guards. The legacy scheduling parser normalizes some invalid components and must
   not be reused blindly for capture tokens. Preserve its existing behavior until
   that separate migration/compatibility decision is tested.
3. Handle non-UTF-8 existing IPTC safely: the pinned writer initially encodes new
   values using the existing encoding. Under-limit Unicode expansions can therefore
   fail before output conversion. Do not simply change the encoding flag and
   reinterpret existing raw bytes. Add real encoded metadata fixtures.
4. Wire asynchronous preview, activated persistence/UI and independent processing
   settings; then bounded providers, companion contracts and remaining M0–M6 gates.
