# Durable processed-file handoff — 2026-10-18

Work on `t3/stabilize-v3-ui`, based on `6ad6aaa`. Host: arm64 macOS 27.0.1
(26A434), Xcode 27.0 (27A266a), development identity 3.0.0 (44).

## Problem and change

Ordinary downloads already used durable grouped publication, but the subsequent
processed-folder handoff imported RAW and XMP individually. An interruption could
leave an unjournaled partial group. Its error rollback unconditionally removed
earlier imports, potentially deleting an operator's concurrent edit or replacement.

Fresh processed copies now use `importFilesTransactionallyIfAbsent` as one group,
with size verification enabled. Production processed roots are local. Their
existing publisher retains a path manifest and output snapshots, publishes with
exclusive renames and revokes only unchanged outputs during rollback. Concurrent
edits retain recovery and block further sync before listing or source removal.

Existing collision prechecks, exact-copy recovery, source snapshot verification
and final verified source removal remain in their original order. Source removal
still starts only after the processed group commits. Unsupported grouped endpoint
implementations retain the existing fail-closed default; no fallback to individual
RAW/XMP publication was added.

## Hosted verification

The final complete unsigned application target passes **1,319 tests, 30 expected
opt-in skips, zero failures**, exit 0 (43.2 seconds). Log:
`build/processed-handoff-full.log`. Initial focused local-sync/publication checks
passed 69 tests before the source-companion and late-collision assertions were
added; the final full target includes those additions.

The final unsigned arm64 Release build passes, exit 0
(`build/processed-handoff-release.log`). Bundled-model verification,
security/development-identity guards and diff whitespace checks pass.

Three new `LocalSyncIntegrationTests` exercise 12 filesystem/engine combinations:

- Custom and managed folders, cancellation at `prepared`, first RAW publication
  and `beforeCommit`: no partial processed outputs or recovery remain after
  successful rollback; source RAW/XMP bytes and dates survive. Fresh retries
  publish the pair, retain the scheduled headline and remove both sources.
- Custom and managed folders, in-place edits and atomic inode replacement after
  RAW publication: edited bytes survive, sources remain unchanged, and recovery
  retains the original RAW snapshot and a two-output path map. Two further sync
  attempts reject admission without changing the manifest or source/edit bytes.
- Custom and managed folders, a competing XMP appearing after RAW publication:
  the competing file survives, the unchanged RAW output rolls back, sources
  remain intact and no unresolved transaction remains. A later run refuses the
  partial competing group and still preserves the sources and competing XMP.

Inputs are synthetic RAW bytes and a generated source XMP with a caption and
City. These are filesystem/recovery fixtures, not camera-format or real-image
acceptance evidence. Existing sorted processed RAW success and identical-copy
retry regressions remain in the passing full suite.

Independent source/test review found no blocker. The old single-file processed
import helper and unconditional rollback loop were removed rather than retained
as an alternate publication path.

## Setup verification completed alongside this change

The user-authorized desktop rerun passes all six pending signed server/setup UI
cases together, zero failures or skips. Both different-protocol custom-port cases
pass. The job connection-sheet screenshot was inspected. See the updated
[setup evidence](2026-10-18-Server-Setup-Stability.md). These configuration-only
cases do not establish native processed-handoff interruption behavior.

## Limits and next actions

Native SIGKILL during the processed handoff, real camera RAW/sidecars, reconciliation
through the app, and final signed candidate acceptance remain open. This slice
uses controlled thrown failures rather than a killed process. The shared durable
publisher already has ordinary-publication interruption evidence, but that does
not replace the processed-handoff native gate. Additional snapshot/copy overhead
has not been measured against release throughput budgets. Supported-macOS and
VoiceOver verification remain open. M5 remains open and the historical candidate
stays IMPLEMENTING. Private checklist observations and candidate records were not
changed.
