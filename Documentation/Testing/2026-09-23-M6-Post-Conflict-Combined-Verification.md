# Combined 3.0 development verification after native conflict coverage — 2026-09-23

Source under test: `5a2afb9` and its ancestor commits through `58a7a0a`.
Host: macOS 27.0 (26A428), Xcode 27.0 (27A266a). The app identifies as
3.0.0 (38), a development build. Both suites used isolated fixtures and did
not enable production jobs or people libraries.

| Check | Result |
| --- | --- |
| Complete non-UI XCTest suite | 1,272 executed, 25 opt-in skips, zero failures |
| Complete signed native UI suite | 34 executed, zero failures |
| Bundled AuraFace source and built Debug app verification | Passed |
| Vendored SSH signature regressions | 2 passed |
| Disposable PHP/MariaDB calendar integration | Passed |
| Loopback FTP/FTPS/SFTP integration | 16 passed |
| Checklist-server regressions | 5 passed |
| Development identity and security baseline guards | Passed |
| RAW/XMP verifier contracts | 10 passed, including synthetic Unicode XMP read by ExifTool |

The full suites ran after the native calendar conflict fixture was committed.
The non-UI result is in `build/v3-final-nonui-sep23.log` and its Xcode result
bundle under `build/v3-remote-transport-sep23/Logs/Test/`. The signed UI result
is in `build/v3-final-ui-sep23.log` and its result bundle under
`build/v3-calendar-conflict-ui/Logs/Test/`. These paths are ignored local build
artifacts. The first non-UI attempt was blocked by Xcode package-cache sandbox
access; the permitted rerun passed. The signed UI run took about 882 seconds.

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/v3-remote-transport-sep23 \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/v3-calendar-conflict-ui
python3 Tools/verify_bundled_auraface.py app \
  'build/v3-calendar-conflict-ui/Build/Products/Debug/Aagedal FTP Sync.app'
```

See [server and transport verification](2026-09-23-M6-Server-and-Transport-Verification.md)
for the other commands and scope. The passing suites do not close authorized
real-photo recognition evaluation and companion-generated schema-3 import,
camera RAW/external-reader and Photo Agent acceptance, controlled enriched
performance, macOS 14/VoiceOver, native job interruption, a newly identified
signed Release candidate, the 41 manual checklist cases, independent review,
or final user acceptance.
