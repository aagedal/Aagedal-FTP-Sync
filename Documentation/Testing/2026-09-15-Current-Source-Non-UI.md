# Current-source non-UI regression — 2026-09-15

Source: `fb4893d` on `codex/version-3-0-plan`, clean before and after the run.
The latest app-code commit is `7907b8c`, and the latest test-code commit is
`c61a49e`. The tracked development candidate still points to `9f04fad` and
was not changed. Host: macOS 27.0 (`26A428`), arm64.

`xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync
-configuration Debug -destination 'platform=macOS,arch=arm64'
-derivedDataPath build/v3-media-live -parallel-testing-enabled NO
'-only-testing:AagedalFTPSyncTests' CODE_SIGNING_ALLOWED=NO` passed with exit 0:
1,154 executed, 18 opt-in skips, zero failures (1,136 passed). The ignored log
is `build/v3-current-full-nonui.log`. Fourteen localhost transport cases were
skipped in this general run because their services are opt-in; all 14 passed
in the separate disposable loopback suite at `c61a49e`. The other opt-in skips
cover the pinned real model, large-tree benchmark, PHP calendar fixture and
million-record store. The current app-code MCP bridge test passed within the
general suite. `python3 Tools/MetadataMCP/test_metadata_mcp.py` also passed
2/2 with exit 0.

The first default-sandbox command attempt stopped during Swift package resolution
with exit 74 because compiler/package caches outside the workspace were denied.
The authorized run of the same command passed; no source change was needed.

This updates current-source non-UI evidence. It does not cover the signed UI
suite, VoiceOver, macOS 14, production model/face calibration, release/security
guards, a signed archive or the human acceptance checklist.
