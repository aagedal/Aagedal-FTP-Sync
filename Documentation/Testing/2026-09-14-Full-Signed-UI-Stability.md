# 3.0 full signed UI stability follow-up

Date: 2026-09-14  
Implementation commit: `55bf697e7e706866746b4f2453020ddf8c8778cc`  
Host: macOS 27.0 (`26A428`), Apple silicon

## Result

The complete signed UI smoke suite passes after correcting the nested-sheet
accessibility hierarchy and hardening launch/menu setup against bounded macOS scene
restoration delays:

- 18 passed, 0 failed, 0 skipped;
- both variable-editor cases that previously reached the SwiftUI/AppKit recursive
  accessibility-label crash now pass;
- recovery, migration, configuration transfer, metadata programming, map editing,
  accessibility text size and menu-bar workflows pass in the same clean run;
- no app crash or crash-dialog interference occurred.

The product fix hides modal background content from accessibility while the clip editor
and its nested variable sheet are presented. The presented controls remain exposed.
The UI harness now uses stable keyboard editing and status-panel routes where window
scroll/restoration made direct controls unreliable, waits for configuration menu items,
and permits one bounded same-process relaunch when SwiftUI restores only the menu-bar
scene during rapid isolated test launches.

## Evidence

Full signed UI result:

`build/v3-ax-final-full-ui/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.14_23-19-26-+0200.xcresult`

- result: passed
- 18 total, 18 passed, 0 failed, 0 skipped
- elapsed test operation: 716.301 seconds
- runtime warnings: seven quality-of-service priority-inversion diagnostics and one
  SwiftUI "Publishing changes from within view updates" diagnostic; none failed a test

Focused variable-editor result used before the clean sweep:

`build/v3-ax-modal-ui/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.14_22-56-35-+0200.xcresult`

- 2 passed, 0 failed, 0 skipped

Complete non-UI result:

`build/v3-ax-final-nonui/Logs/Test/Test-AagedalFTPSync-2026.09.14_23-32-56-+0200.xcresult`

- 1,146 total, 1,130 passed, 0 failed, 16 opt-in skips

Additional checks:

```text
Scripts/check-security-baseline.sh
PASS — Security dependency baseline verified.

Scripts/check-release-identity.sh
PASS — Release identity verified for 2.9.2 (build 37).

python3 Scripts/test-3.0-checklist.py
PASS — 5 passed.

xcodebuild build -scheme AagedalFTPSync -configuration Release \
  -destination 'platform=macOS,arch=arm64' ... CODE_SIGNING_ALLOWED=NO
PASS
```

Release output:

`build/v3-ax-final-release/Build/Products/Release/AagedalFTPSync.app`

The executable is arm64 with SHA-256
`a963a2ecf8de1fe07d8cfdcac47a83c631012bff953f53a07e86301318d79953`.
The bundle remains version 2.9.2 (37), so this is a development verification build,
not a beta or release candidate.

## Remaining acceptance

The accessibility crash gate is closed for XCTest on this host. Native VoiceOver
observation, supported-macOS coverage and investigation of the non-failing SwiftUI
runtime warning remain separate acceptance work. Production face-model trust and
artifacts, calibrated actual-face evidence, live integration matrices, enriched
performance, the 3.0 identity cut, a signed archive and user acceptance are also still
required before final release.
