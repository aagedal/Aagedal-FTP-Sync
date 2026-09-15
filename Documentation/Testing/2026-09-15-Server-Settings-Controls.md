# Servers settings controls, 2026-09-15

The native Servers split divider reached into the Settings tab strip and crossed
the selected Servers icon. The Servers view now places its divider between the
sidebar and editor content, so it begins below the tab controls. The sidebar is
280 points wide, and its add, duplicate, and delete controls each have a visible
36 × 36 point target. The existing selection, usage guard, and delete confirmation
remain in effect.

A focused signed macOS UI test passed on Xcode 27.0. It opened Settings with a
disposable server profile in a per-session temporary store, measured the delete
button, clicked near its lower-right corner, confirmed deletion, and checked that
the profile disappeared. The test's retained screenshot was inspected: the
divider starts below the tab strip and the Servers icon is clear. The result is
in `build/v3-startup-ux/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.15_23-33-51-+0200.xcresult`.

`Scripts/check-security-baseline.sh`, `Scripts/check-release-identity.sh`, and
`git diff --check` passed. The Xcode command used scheme
`AagedalFTPSyncUISmokeTests`, derived data `build/v3-startup-ux`, cloned packages
`build/SourcePackages`, `-parallel-testing-enabled NO`, and a temporary
`TEST_TARGET_NAME=Aagedal FTP Sync` override for unrelated uncommitted target
renaming in the workspace. Those Xcode and localization edits were left unstaged.
