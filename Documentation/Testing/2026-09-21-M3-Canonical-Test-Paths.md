# Physical temporary paths for storage regressions — 2026-09-21

Source fix: `e99bb4092a63f6a36b50ff4811431b920cce1ae0`, on
`codex/version-3-0-plan`. Host: arm64 macOS 27.0 (`26A428`), Xcode 27.0
(`27A266a`); development identity 3.0.0 (38).

## Cause and change

The earlier complete suite recorded 52 failure assertions across four storage,
SQLite acquisition, migration and startup test classes. Their disposable roots
used Foundation's `resolvingSymlinksInPath()`, which retained the `/var` system
alias on this host. Strict no-follow storage admission correctly rejected those
paths; downstream tests then failed before exercising their intended scenarios.

All four fixture factories now canonicalize the trusted system temporary parent
with the existing `Version3StartupPaths.canonicalDirectory` helper, which uses
`realpath` and verifies directory identity. Unique disposable children and their
existing cleanup remain unchanged. Production admission is unchanged: imported
paths, symlinked roots/parents/files, hardlinks and unsafe SQLite companions
still face the existing rejection checks. The full suite also exercises the
startup helper's alias and final-symlink regression tests.

## Verification

The focused selection passed 63 tests, zero failures, exit 0. This includes
preserved WAL evidence, interrupted migration, committed-store validation,
symlink/hardlink rejection, competing leases and isolated startup.

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/VersionedAppStorageTests \
  -only-testing:AagedalFTPSyncTests/Version3MigrationDriverTests \
  -only-testing:AagedalFTPSyncTests/LegacySignatureSQLiteAcquisitionTests \
  -only-testing:AagedalFTPSyncTests/Version3StartupControllerTests \
  CODE_SIGNING_ALLOWED=NO
```

The complete non-UI suite passes at `e99bb40`: 1,266 executed, 1,241 passed,
25 opt-in skips, zero failures, exit 0 (56.916 seconds). Full result:
`Test-AagedalFTPSync-2026.09.21_11-57-56-+0200.xcresult`.

Full-suite command uses the same settings with the selection replaced by
`-only-testing:AagedalFTPSyncTests`. Logs:
`build/v3-storage-temp-focused.log` and `build/v3-storage-temp-full.log`.
Focused result: `Test-AagedalFTPSync-2026.09.21_11-57-23-+0200.xcresult`
under `build/v3-preview-consistency/Logs/Test/`.

The restricted initial invocation could not write SwiftPM/Clang caches;
approved Xcode execution completed the focused run. Security baseline,
development identity and diff whitespace checks pass.

The focused run began at `4752752` with the four-file fixture diff; those exact
changes were committed in the shared checkout as `e99bb40` before the full run.
No other source changes were included by this task.

## Remaining gates

This repairs local regression setup. It does not establish the GitHub Xcode 26.6
result, macOS 14 runtime compatibility, native UI acceptance or release readiness.
Other project tasks were active on the shared desktop; no desktop interaction
was performed. No private results JSON was present, and the historical candidate
and checklist lanes remain unchanged. Continue native scoped image recovery and
camera RAW/XMP acceptance after this regression gate is restored.
