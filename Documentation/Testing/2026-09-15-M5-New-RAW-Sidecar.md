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
