# M5 reviewed-edit revision guard — 2026-09-15

Implementation source: `7fe95b9b41302825d0fa89b82e48804633f192dc` on
`codex/version-3-0-plan`. The worktree was clean when the focused tests ran.
Host: macOS 27.0 (`26A428`), Apple silicon. The app remains a 2.9.2 (37)
development build; the tracked candidate was not changed.

The reprocessing preflight now captures the complete output revision for each
edited-output conflict, including an existing RAW XMP sidecar. The explicit
reviewed-edit action carries those path/revision pairs. Reprocessing includes an
edited output only if its staged bytes still match the revision inspected by
preflight. An edit made after review remains a reported conflict and is preserved.
The default safe action continues to preserve every edited output.

An unsigned macOS test run of
`ActivatedMetadataSyncIntegrationTests` with derived data at
`build/v3-reviewed-edits` passed 19/19 with exit 0. The new interval fixture
edits an approved output again after preflight, then proves the later bytes
remain intact and the output is reported as a conflict. Existing fixtures
still prove that an unchanged reviewed edit applies and that a different path
edited after preflight stays protected. Result bundle:
`build/v3-reviewed-edits/Logs/Test/Test-AagedalFTPSync-2026.09.15_14-45-22-+0200.xcresult`.

An already-built `test-without-building` run of
`MetadataProgrammingCoordinatorTests` passed 40/40 with exit 0. Result bundle:
`build/v3-reviewed-edits/Logs/Test/Test-AagedalFTPSync-2026.09.15_14-46-52-+0200.xcresult`.
`Scripts/check-security-baseline.sh`, `Scripts/check-release-identity.sh` and
`git diff --check` passed. The first sandboxed build attempt stopped at package
resolution with exit 74 because Xcode's compiler caches were denied; the
authorized retry passed. Logs remain in ignored `build/` paths.

This verifies the preflight-to-reprocess edit interval in a disposable local
fixture. The complete M5 delivery/idempotence/rollback matrix, native dialog
observation, live transport conflict handling, macOS 14 and release-candidate
checks remain open.
