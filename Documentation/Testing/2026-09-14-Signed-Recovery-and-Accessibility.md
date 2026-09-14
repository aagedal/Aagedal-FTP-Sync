# 3.0 signed recovery UI and accessibility follow-up

Date: 2026-09-14  
Implementation commit: `57188ae1e0b23ac5175e6326d6997094ef66b2c4`  
Signed UI source before mitigation: `5db5b06` (app code through `ade3c2d`)  
Host: macOS 27.0 (`26A428`), Apple silicon

## Result

The two remaining recovery UI fixtures passed in a focused signed run:

- a damaged primary store fails closed and never silently falls back to a backup;
- an interrupted `PREPARED` migration resumes from its frozen version 3 snapshot and
  does not re-import a later legacy edit.

The subsequent full signed UI suite ran 18 tests: 16 passed and 2 failed. The first
failure lost the application while XCTest requested an accessibility snapshot during
the variable-editor workflow. The app crash report records `EXC_BAD_ACCESS` after a
very deep recursive stack in SwiftUI/AppKit accessibility-label resolution. The next
test found the timeline clip but could not hit it because the prior app-crash dialog
remained in front; it is not counted as an independent product failure.

Commit `57188ae` keeps each timeline clip exposed as a single accessible control but
uses SwiftUI's no-argument accessibility element form instead of explicitly re-parenting
ignored descendants. This removes the operation present in the recursive stack. The
mitigation compiles in the complete UI test bundle and in an unsigned arm64 Release
build. It has not yet received a native UI rerun because the Mac locked while the owned
crash dialog was being dismissed.

## Evidence

Focused recovery result:

`build/v3-recovery-ui-current/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.14_16-12-27-+0200.xcresult`

- 2 passed, 0 failed, 0 skipped
- runtime warnings: none

Broad UI result:

`build/v3-full-ui-current/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.14_16-14-40-+0200.xcresult`

- 18 total, 16 passed, 2 failed, 0 skipped
- failed first: `testVariableApplyRetainsSourceAndKeywordsCancelKeepsList()` — lost
  connection to the crashed app
- failed second: `testVariableDraftRejectsInvalidActivationAndCancelKeepsLiteralHeadline()`
  — clip existed but was not hittable behind the crash dialog

Post-mitigation checks:

```text
xcodebuild test -scheme AagedalFTPSync ... \
  -only-testing:AagedalFTPSyncTests CODE_SIGNING_ALLOWED=NO
PASS — 1,130 passed, 16 opt-in skips, 0 failed (1,146 total)

xcodebuild build-for-testing -scheme AagedalFTPSyncUISmokeTests ... CODE_SIGNING_ALLOWED=NO
PASS

Scripts/check-security-baseline.sh
PASS — Security dependency baseline verified.

Scripts/check-release-identity.sh
PASS — Release identity verified for 2.9.2 (build 37).

xcodebuild build -scheme AagedalFTPSync -configuration Release \
  -destination 'platform=macOS,arch=arm64' ... CODE_SIGNING_ALLOWED=NO
PASS
```

Release output:

`build/v3-ax-fix-release/Build/Products/Release/AagedalFTPSync.app`

The executable is arm64 with SHA-256
`4961a80ff87e4feec83b5e3e5cfdb27b907444fba78e9d03d6249e937fe38bf0`.
The full test result is
`build/v3-ax-fix-nonui/Logs/Test/Test-AagedalFTPSync-2026.09.14_18-54-32-+0200.xcresult`.
This remains a development build at version 2.9.2 (37), not a beta or release candidate.

## Remaining acceptance

After the Mac is unlocked, dismiss only the owned QA crash dialog and rerun the two
variable-editor tests first. If they pass, rerun the complete signed UI suite from a
clean desktop. Native VoiceOver observation and supported-macOS coverage remain separate
release gates even if XCTest no longer reproduces the recursion.
