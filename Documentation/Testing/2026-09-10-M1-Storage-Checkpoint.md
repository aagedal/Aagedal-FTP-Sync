# 3.0 activation, resolved writer and storage foundations

Recorded 2026-09-10, starting at `53dbe30` on `codex/version-3-0-plan`.
Status remains **IMPLEMENTING**, with no release candidate. No human checklist
results file existed at the final check; no human results were written.

## Implementation and review

- `326fcb0` adds atomic source/activation values to the isolated template package.
  Literal values bypass parsing, while activated text and keyword arrays validate
  language version and syntax. Missing activation remains legacy; explicit null,
  wrong types, unknown keys and unsupported versions fail decoding. This codec is
  a core value envelope, not an implemented calendar/configuration wire format.
- `ResolvedMetadataChanges` freezes final writer inputs without being Codable.
  Assessment and embedded/sidecar writers accept this same value. Existing callers
  use a literal adapter preserving keyword normalization, photographer fallback,
  empty-field behavior and existing metadata policies. The writer does not parse
  templates or independently obtain date/location/person values.
- `VersionedAppStorage` is an opt-in migration primitive with a retained original
  snapshot, validated staging, atomic boundary/install publication and explicit
  recovery. It has no production startup/repository callers. See the complete
  [storage inventory and integration requirements](3.0-Storage-Inventory.md).
- Independent review found and resolved atomic PREPARED-marker publication and
  directory-sync gaps in the helper. Writer review strengthened omission checks
  to reread both IPTC and XMP and compare canonical decoded JPEG pixels.

The coordinator reviewed and integrated disjoint agent changes. XcodeGen adds the
two app files and two XCTest files; its Packages group now points at the existing
Packages directory. The vendored Citadel reference remains relative to SOURCE_ROOT.
No package dependency, app version, user-facing activation or default storage root
has changed. The installed stable app was not replaced.

## Verification

The activation package passes **29 tests**, zero failures/skips, using:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/Packages/MetadataProcessing/.build/clang-module-cache" swift test --package-path Packages/MetadataProcessing --cache-path Packages/MetadataProcessing/.build/cache --config-path Packages/MetadataProcessing/.build/config --security-path Packages/MetadataProcessing/.build/security --disable-sandbox
```

The storage helper separately passed 14 tests with Swift 6 and deployment target
macOS 14; the inventory records its exact harness command and source/log hashes.
These are not production migration, actual SQLite WAL, power-loss or separate
process exclusion tests.

The initial focused Xcode run compiled but stalled before any tests executed.
A two-second process sample showed XCTest waiting in
`_prepareTestConfigurationAndIDESession`. It was interrupted (exit 75).
A full single-worker retry then failed (exit 65): the runner hung before connection,
and initiating the daemon control session timed out. Neither attempt is a pass.
The read-only computer-use call inspecting Xcode also stalled for several hours;
on return it showed another project's editor, with no permission prompt in that
window. No FTP Sync GUI workflow was exercised during this slice.

A later full retry uses the same source and this command:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

The unchanged-source retry completed at 09:48:49 Europe/Oslo with exit 0:
**513 discovered, 498 passed, 15 opt-in skips, zero failures**, 29.379 seconds
of test execution. All four new writer tests and 14 storage tests passed inside
the actual app test target. The verified app source is committed as `e2e38e2`;
only documentation remained dirty after that commit. This establishes the unit
integration boundary, not signed GUI or live-provider behavior.

Logs and the startup sample are retained under ignored `build/m1-foundations/`.
The successful `ftp-m1-full-retry-tests.log` SHA-256 is
`406363a71bb8c9fa3aed057be53e66845aa464a2356d27091e750bf3777895f1`;
the package log SHA-256 is
`96145eafa9df8dd203e389081c34759d79713972a2d8d624c5ed2f1fffba96ad`.
The successful result bundle is
`~/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.10_09-48-15-+0200.xcresult`.

Current host reports macOS 27.0 **26A428**, Xcode 26.6 **17F113**. The prior
checkpoint's OS build is historical evidence, not the environment for this run.
The app is still a development 2.9.2 (37) binary in Xcode DerivedData; deployment
target 14 compilation does not establish macOS 14 runtime support.

## Remaining work

Bind the package to the processing coordinator, freeze actual per-image context,
map typed outcomes, enforce writer/server limits and share the result across
preview, transfer and reprocessing. Add activation UI only after durable schema
adapters and v3 storage separation are integrated.

Production migration needs complete writer exclusion before repositories perform
their existing migrations, a consistent SQLite adapter, schema/reference checks,
root injection, retained-backup credential reachability, recovery UI and current-v3
backups. The helper requires a trusted, stable root and cannot itself prove a
cross-store transaction or resist adversarial ancestor-directory swaps.

Actual GUI, supported-OS, provider, model, companion-server and final candidate
gates remain open. No milestone checkbox or final checklist case is marked passed
by these foundation tests. The automation remains active and the no-progress
counter remains zero because implementation progressed.
