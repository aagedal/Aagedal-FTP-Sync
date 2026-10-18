# Late source-sidecar edits during processed handoff — 2026-10-18

## Coverage

Base `f625aa6` plus pending setup source already verifies sources before processed
publication and checks the whole staged source group again before deleting any
member. Existing tests cover source changes during geocoding, cancellation,
processed-output edits and late output collisions. They did not exercise an
original source XMP changing after that first verification, while processed
outputs were visible, followed by the final staged-byte check and fresh retries.

The new hosted regression uses a synthetic CR3 payload and serialized original
XMP in a nested source folder. For both custom and managed processed roots it
changes only the original caption at processed `beforeCommit`, after both output
members are visible. The edit has equal byte length, preserves the inode, and
restores the original modification date. Processed publication then commits before
the final source-removal verification runs.

The engine rejects removal with the source-changed failure and zero processed
files. RAW and edited XMP are restored with unchanged bytes, timestamps and file
identities. Completed processed copies retain the original caption plus the
scheduled headline, and the synced copy exists at the folder mode's correct path.

A fresh engine sharing isolated signature/manifest repositories retries twice.
Each attempt rejects the mismatching existing processed group, retains the edited
source pair, and leaves processed bytes, dates and inodes unchanged. The test
therefore covers the final byte guard, group restoration and the identical-copy
retry boundary. No production change was needed.

## Verification

Five focused tests pass with zero failures/skips, exit 0, 2.239 seconds:
`build/late-source-sidecar-handoff-focused.log`. They include the new late-source
case alongside cancellation rollback, concurrent processed edits, late output
sidecar collision and identical-copy retry regressions. Independent source/test
review found no blockers.

The full combined-worktree hosted target passes 1,344 tests with 30 expected
opt-in skips and zero failures, exit 0, 44.146 seconds:
`build/late-source-sidecar-handoff-hosted.log`. Diff whitespace checks pass.
This change adds only test and evidence coverage; application source and
production behavior are unchanged.

The fixtures are disposable synthetic RAW bytes and generated XMP, not original
camera media or camera-authored sidecars. No process kill, native desktop use,
remote transport, throughput or final-candidate acceptance is established here.
Those M5/release requirements remain open, and the user's desktop wait remains
in force.
