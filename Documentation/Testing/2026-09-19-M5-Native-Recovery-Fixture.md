# Native metadata recovery fixture — 2026-09-19

Source: clean `fe22dac` plus the fixture, tests and documentation committed with
this report on `codex/version-3-0-plan`. App identity remains 2.9.2 (37).
Host: Apple silicon, macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`).

## Changes

The existing UI fixtures use placeholder bookmarks suitable for editing jobs,
but cannot reach real local recovery admission. An explicit
`AAGEDAL_UI_TEST_RECOVERY=1` launch option now creates real bookmarks inside the
existing isolated UI-test session. It enables offline City processing, retains
an original and output snapshots with a version-1 path manifest, and leaves a
visible disposable text file in the destination. No network or real photos are
used. Jobs remain disabled and do not start automatically.

A seed marker prevents later launches from recreating reconciled recovery or
overwriting edits made during inspection. A focused regression exercises real
bookmark resolution and admission: the source is usable, destination admission
reports the retained folder, repeated seeding preserves review edits and original
bytes, and admission succeeds after the retained original is rescued and the
transaction removed. The rescued original and chosen visible output remain intact.

A new native test opens saved-file reprocessing, expects the recovery path and
instructions, verifies that publication is unavailable, dismisses the dialog and
retries preflight. It compiles but has not been executed.

## Verification

Commands (all from the repository root):

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests CODE_SIGNING_ALLOWED=NO
xcodebuild build-for-testing -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

Publication suite: 19 executed, 16 passed, three opt-in skips, zero failures,
exit 0. Log: `build/v3-native-recovery-tests.log`. Signed UI test compilation:
exit 0, `build/v3-native-recovery-ui-build.log`. Security, identity and diff checks
pass. Xcode needed approved compiler/package-cache access.

The first signed development build was launched with the isolated
`recovery-native-20260919` session. The sandboxed command failed before producing
app output; the approved launch remained running. Computer-use attachment using
the exact app path returned `timeoutReached` twice. No native error dialog,
reconciliation or successful retry was observed. The isolated process was then
terminated; unrelated applications were left alone. The final signed UI build
includes the subsequently added manifest and regression.

Final app: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.
Executable SHA-256:
`c672bb37a6baf4edaeda449a1bcc65ce0031c088169cdf74701117882cd32b99`.
`codesign --verify --deep --strict` passes with approved trust-service access;
the sandboxed check returned `CSSMERR_TP_NOT_TRUSTED`.

## Remaining gates

This is test infrastructure and non-UI admission evidence, not native acceptance.
The fixture uses synthetic text bytes, not a camera RAW/XMP publication. Run the
new native test and manually reconcile the fixture when desktop access works;
then cover both editors, directions, managed/custom output folders and actual
process interruption through the native workflow. Existing candidate identity,
private user results and milestone checkboxes are unchanged. Version 3.0 remains
IMPLEMENTING.
