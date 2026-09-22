# Combined 3.0 development verification — 2026-09-23

Source: `81a391f` plus the UI smoke-test assertions recorded with this note.
Host: macOS 27.0 (26A428), Xcode 27.0 (27A266a). App identity remains
3.0.0 (38), a development build. Tests used isolated fixtures and build
directories; no production job or library was enabled.

## Results

| Check | Result |
| --- | --- |
| Complete non-UI XCTest suite | 1,270 executed, 25 opt-in skips, zero failures |
| Complete signed native UI suite | 31 executed, zero failures |
| Vendored SwiftNIO SSH signature regressions | 2 passed |
| Local checklist-server regressions | 5 passed |
| Release-identity and security-baseline guards | Passed for development identity |
| Bundled AuraFace source and Debug app verification | Passed |
| Unsigned arm64 Release build and bundled AuraFace app verification | Passed; built Info.plist is 3.0.0 (38) |

The first complete UI run failed four cases. The People Library case asserted
the retired model-download text, and the damaged-store case asserted an
obsolete startup sentence. The save-failure test queried an AppKit sheet as a
dialog. The file-filter test intermittently missed its tab through a broad
accessibility query. Tests now assert the bundled-model status, use the
identified startup message and sheet, and select the specific tab radio
button. Isolated diagnostics established the actual UI state; the complete
rerun then passed all 31 cases. A full suite pass on this host is not macOS 14
or VoiceOver evidence.

Commands:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/v3-full-nonui-sep22 CODE_SIGNING_ALLOWED=NO
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/v3-full-ui-sep22
swift test --package-path Vendor/swift-nio-ssh --filter NIOSSHSignatureTests
python3 Scripts/test-3.0-checklist.py
Scripts/check-release-identity.sh
Scripts/check-security-baseline.sh
python3 Tools/verify_bundled_auraface.py source \
  AagedalFTPSync/Resources/Models/AuraFaceR100.mlpackage
python3 Tools/verify_bundled_auraface.py app \
  'build/v3-full-ui-sep22/Build/Products/Debug/Aagedal FTP Sync.app'
xcodebuild build -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/v3-release-sep23 \
  CODE_SIGNING_ALLOWED=NO
python3 Tools/verify_bundled_auraface.py app \
  'build/v3-release-sep23/Build/Products/Release/Aagedal FTP Sync.app'
```

The UI app and runner were signed by Xcode with an Apple Development identity.
The separate `security find-identity -v -p codesigning` inventory returned zero
valid identities on this host; the successful signed test run is the operative
test evidence, not proof that a Release archive can be signed and distributed.
Full results are in `build/v3-full-nonui-sep22/Logs/Test/` and
`build/v3-full-ui-sep22/Logs/Test/`; the Release build log is
`build/v3-release-sep23.log` (ignored local build artifacts).

Final release still needs authorized real-photo recognition evaluation,
same-package companion import acceptance, camera RAW/external-reader checks,
native conflict and interrupted-transaction coverage, controlled enriched
performance, macOS 14 and VoiceOver, all 41 agent checklist cases, independent
review, a newly identified signed candidate and the user's final acceptance.
