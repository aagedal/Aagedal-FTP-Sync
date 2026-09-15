# M5 combined source/output conflict — 2026-09-15

Implementation was tested as the two-file source/test diff on clean base
`835fb582826db224def87d8745701f922292b13d` on
`codex/version-3-0-plan`. The worktree was dirty during testing; the tested
source/test change was committed as `a5eec70`. Host: macOS
27.0 (`26A428`), arm64. The application identity remains the 2.9.2 (37)
development build; the tracked candidate was not changed.

The reprocessing receipt's output revision now protects an edited destination
even when the source revision also changes. Previously, the edit check required
the old and current source revisions to match, so a source resend could hide a
destination edit. The added disposable local test changes the source modification
time, destination bytes and Headline settings after a complete transfer. The
read-only preflight reports one edited-output conflict and preserves the bytes;
the default stale/incomplete reprocessing action also preserves them and retains
the previous complete receipt. Existing changed-source-only cases continue to
resolve without a false edit conflict.

Focused verification:

- `xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme
  AagedalFTPSync -destination 'platform=macOS' -derivedDataPath
  build/v3-reviewed-edits
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests
  CODE_SIGNING_ALLOWED=NO` passed 20/20, exit 0. Result bundle:
  `build/v3-reviewed-edits/Logs/Test/Test-AagedalFTPSync-2026.09.15_15-11-16-+0200.xcresult`.
- The focused programmed-media loopback XCTest passed, exit 0, across disposable
  FTP, trusted implicit FTPS and SFTP using
  `AFTPSYNC_REMOTE_ONLY_TESTING=AagedalFTPSyncTests/RemoteTransportIntegrationTests/testProgrammedDownloadProcessesDecodableJPEGAndValidRAWSidecarAcrossLiveTransports`
  and `Scripts/run-remote-transport-tests.py`. Result bundle:
  `build/v3-reviewed-edits/Logs/Test/Test-AagedalFTPSync-2026.09.15_15-11-53-+0200.xcresult`.
- `Scripts/check-security-baseline.sh`, `Scripts/check-release-identity.sh` and
  `git diff --check` passed.

At a later clean base `5ea4d86`, the disposable programmed-media transport
fixture was extended to change a remote RAW XMP source companion after the
delivered sidecar had been edited locally. For each of FTP, implicit FTPS and
SFTP, preflight reports the RAW path as a conflict; default reprocessing
preserves the local sidecar bytes and opaque RAW primary while the unchanged
JPEG stays current. The focused XCTest passed again with exit 0 against the
one-file uncommitted test diff. Result bundle:
`build/v3-reviewed-edits/Logs/Test/Test-AagedalFTPSync-2026.09.15_15-14-38-+0200.xcresult`.

The initial sandboxed XCTest attempt stopped at package resolution, exit 74,
because Xcode's compiler caches were outside writable roots. The authorized
cache-access retry above passed. Logs are in ignored `build/` paths.

This is a reprocessing guard with generated media. The full M5 matrix,
camera RAW/external-reader integrity, native UI and supported-OS acceptance
remain open.
