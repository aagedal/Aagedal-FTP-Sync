# M5 new RAW sidecar after an incomplete transfer — 2026-09-15

Test base: clean `4c49ff175bf9f0c5d62119569c0e5d55a2420ed8` on
`codex/version-3-0-plan`. The test ran with a one-file uncommitted test diff;
there was no app-code change. Host: macOS 27.0 (`26A428`), arm64. The tracked
2.9.2 (37) development candidate remains unchanged.

The disposable local integration fixture first delivers an opaque `.CR3` without
an XMP companion under standalone geocoding. The result is incomplete, so the
source RAW stays in place and no processed copy is made. A valid GPS-bearing XMP
sidecar then appears beside the unchanged source RAW. The next run delivers an
enriched RAW/XMP pair to the normal output and the custom or managed processed
folder, retains the source Headline, and removes the source pair only after
successful processed publication. An immediately repeated poll is idle. The
same assertions pass for both folder modes.

Focused XCTest passed 1/1, followed by the complete affected
`MetadataGeocodingSyncIntegrationTests` class at 11/11, zero failures:

`xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync
-destination 'platform=macOS' -derivedDataPath build/v3-new-sidecar
-only-testing:AagedalFTPSyncTests/MetadataGeocodingSyncIntegrationTests
CODE_SIGNING_ALLOWED=NO`

Exit status was 0. The class result bundle is
`build/v3-new-sidecar/Logs/Test/Test-AagedalFTPSync-2026.09.15_15-38-48-+0200.xcresult`;
the focused result bundle is the adjacent `15-37-28` bundle. The first
sandboxed attempt could not resolve packages because Xcode's standard caches
were outside writable roots; the authorized cache-access retry passed.
`git diff --check` passed. Logs remain in ignored `build/` paths.

This is generated XMP with opaque synthetic RAW bytes and an injected place
provider. Camera RAW, external-reader integrity, native UI and supported-OS
acceptance remain open.

## Disposable loopback transport follow-up

At clean base `1e94920` plus a one-file uncommitted transport test diff, a
second fixture starts with an opaque remote `.CR3` and no companion. An idle
poll follows the original delivery. It then uploads a valid GPS-bearing XMP
companion while leaving the RAW source unchanged. The next poll reports an
applied outcome for the RAW, retains its payload bytes, writes City and Country
to the delivered XMP, preserves the source Headline, and a subsequent poll is
idle. The same assertions pass over disposable FTP, trusted implicit FTPS and
SFTP services. The service harness confirms no test staging files remain.

`AFTPSYNC_TEST_DERIVED_DATA=build/v3-new-sidecar
AFTPSYNC_REMOTE_ONLY_TESTING=AagedalFTPSyncTests/RemoteTransportIntegrationTests/testLateRAWSidecarEnrichesUnchangedRemotePrimaryAcrossLiveTransports
build/3.0-benchmark-venv/bin/python Scripts/run-remote-transport-tests.py`
passed with exit 0. Result bundle:
`build/v3-new-sidecar/Logs/Test/Test-AagedalFTPSync-2026.09.15_15-43-05-+0200.xcresult`.

The first attempt had two fixture mistakes: the unrestricted filename filter
selected the harness's rollback seed file, and cleanup used a session closed
by the engine. Narrowing the test filename prefix and reconnecting for cleanup
resolved both. The corrected run passed. This adds live transport behavior with
generated media; it does not validate camera RAW or the actual app UI.
