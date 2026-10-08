# M5 reviewed-edit revision guard — 2026-09-15

Implementation source: `7fe95b9b41302825d0fa89b82e48804633f192dc` on
`codex/version-3-0-plan`. The focused tests ran against the equivalent three-file
uncommitted diff on base `6aba497`; the worktree was dirty during the run, then
the exact tested source was committed as `7fe95b9`.
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
fixture. A later test-only commit, `5733239b6874a71454663acb83438378cab80dee`,
extends the disposable programmed-media fixture across FTP, implicit FTPS and
SFTP. That focused run used the equivalent one-file uncommitted test diff on
base `34baa38`; the exact tested source was then committed as `5733239`. The
focused
`RemoteTransportIntegrationTests/testProgrammedDownloadProcessesDecodableJPEGAndValidRAWSidecarAcrossLiveTransports`
run passed with exit 0 in 1.088 seconds. For each transport, it reviews a local
edit to the delivered RAW XMP sidecar, edits the same sidecar again before
reprocessing, and verifies that the later bytes remain intact and the RAW path
is reported as a conflict. The decodable JPEG still receives the changed
Headline; the opaque `.CR3` payload stays byte-identical. The ignored log is
`build/v3-reviewed-edits-live.log`; the result bundle is
`build/v3-reviewed-edits/Logs/Test/Test-AagedalFTPSync-2026.09.15_14-49-54-+0200.xcresult`.

The complete M5 delivery/idempotence/rollback matrix, native dialog
observation, camera RAW/external-reader integrity, macOS 14 and
release-candidate checks remain open.
