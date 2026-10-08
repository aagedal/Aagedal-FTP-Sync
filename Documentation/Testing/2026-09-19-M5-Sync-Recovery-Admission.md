# M5 ordinary-sync recovery admission — 2026-09-19

Source: clean `e4ced1f` base plus the source, tests and documentation committed
with this report on `codex/version-3-0-plan`. Host: arm64 macOS 27.0 (`26A428`),
Xcode 27.0 (`27A266a`). App identity remains 2.9.2 (37). No private results JSON
was present; the earlier development candidate remains unchanged.

## Defect and change

Retained metadata/reset recovery folders blocked reprocessing and Reset Job,
but ordinary sync still admitted incomplete local listings. A restarted job could
fill a missing original path or deliver a partially published result before the
user reconciled recovery. This also affected jobs with metadata disabled.

Every run now validates its raw local left/right sessions and optional processed
destination before starting any listing task. Checking before concurrent listings
also precedes completed-directory early delivery. Raw sessions are inspected before
naming wrappers can conceal their local type. Admission errors use the existing
session-close/error-reporting path, identify the retained recovery folder, and
explain that sync and reprocessing require reconciliation.

Two new integration tests cover 16 disposable combinations: left-to-right,
right-to-left and bidirectional runs with recovery on either side, both transaction
and reset artifacts, and ordinary/managed destinations plus custom/managed processed
folders. They verify retained bytes, no new publication, unchanged download history
in the direction matrix, and successful retry after removing the resolved fixture.

## Verification

The two tests against unchanged application code fail with 47 assertions, reproducing
unwanted publication before reconciliation and the resulting already-completed retry. Log:
`build/v3-sync-recovery-before.log` (exit 65).

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/LocalSyncIntegrationTests CODE_SIGNING_ALLOWED=NO
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

Focused suite: 101 executed, 100 passed, one opt-in recovery-scan benchmark skipped,
zero failures (exit 0). Security/identity guards and diff validation pass.
Full non-UI suite: 1,212 executed, 1,191 passed, 21 skipped, zero failures
(exit 0). Skipped opt-in cases are not acceptance evidence.
Xcode required approved access to its compiler/package caches after the initial
sandboxed attempt could not resolve dependencies.

Focused log: `build/v3-sync-recovery-after.log`.
Focused result: `build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_22-07-41-+0200.xcresult`.
Full log: `build/v3-sync-recovery-full.log`.
Full result: `build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_22-08-13-+0200.xcresult`.
App: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.

## Remaining acceptance

These tests create retained recovery fixtures; they do not terminate a live process
or establish power-loss durability. The new check is run admission, not a filesystem
lock against other processes creating recovery later. Existing reprocessing boundary
rechecks remain intact. No native recovery dialog, real remote early-delivery,
supported-OS, camera RAW or real-model acceptance is claimed. Other project tasks
were active on the shared desktop; no desktop automation was used. Native observation,
actual process-interruption testing, full-batch performance and final candidate gates
remain open. No milestone or checklist gate is closed by this report.
