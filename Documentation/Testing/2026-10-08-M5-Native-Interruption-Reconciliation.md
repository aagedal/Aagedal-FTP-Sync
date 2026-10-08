# Native interrupted-image reconciliation — 2026-10-08

## Source and scope

Tested source: `ee51733` plus the three source/test changes committed as
`11cb1590042fd2fac7e6f48e73f6f54163e935f1`, on
`t3code/continue-3-0-implementation`. No unrelated changes were present.
Host: Mac17,8, arm64, 64 GiB RAM, macOS 27.0.1 (26A434),
Xcode 27.0 (27A266a).
App: `build/continuation-tests/Build/Products/Debug/Aagedal FTP Sync.app`,
3.0.0 (44), Apple Development signed for the native run. The later unsigned
unit run rebuilt that same development path; use the native result bundle as
the signed-run record. The tracked Developer ID Release candidate is unchanged.

The two existing native SIGKILL tests now continue past recovery rejection to
explicit test-assisted reconciliation, successful publication, and another
relaunch. Both ordinary and managed `Synced Files` destinations pass. The image
is the existing generated 4×4 JPEG with GPS, and City resolves through the fixed
local `Recovery Venue` polygon; no network or real-model inference is involved.
No private photo, credential, normal app store, or live job is used.

## Observed behavior

The isolated DEBUG app is interrupted at `beforeCommit` after JPEG publication.
Relaunch exposes the actual transaction path, blocks reprocessing, and retains
the original after Cancel. The test checks the manifest path, original/source
bytes, published IPTC City, and original filesystem modification date.

An explicit DEBUG launch option then chooses the retained original. Before any
write, the helper checks the seed/interruption markers, a single transaction,
the exact one-image manifest, regular files without redirected paths, and
agreement between source/held/snapshot and visible/published-snapshot bytes.
It preserves the visible publication and moves the intact transaction outside
the destination only after restoring the original with its modification date.
This is isolated test plumbing, not a new automatic production recovery action.

Native preflight then finds one file and leaves its bytes unchanged. Clicking
Reprocess Saved Files reports one applied file, zero skips and zero failures.
Independent ImageIO readback confirms City `Recovery Venue`; source bytes and
the output modification date remain unchanged. Another relaunch finds a current
receipt with no enabled publication action and preserves the retry output,
rescued publication, retained original, and manifest.

Two unit regressions exercise both folder modes, preserved choices, idempotence,
and rejection before mutation for changed source/output, a held-file symlink,
manifest traversal, a competing transaction, and a prior rescue file.

## Verification and reproduction

| Check | Result |
| --- | --- |
| Final focused LocalMatchingPublicationTests | 30 executed, four opt-in skips, zero failures; exit 0 |
| Signed native interruption/reconciliation | Two executed, zero skips/failures; exit 0; 75.13 s |
| Development release identity/security baseline | Both pass; exit 0 |
| Diff whitespace check | Pass; exit 0 |

The first unit invocation could not write compiler/package caches through the
filesystem sandbox. The successful run used its own copied package cache and
Xcode service/cache access. No shared worktree cache was modified. The initial
focused run also passed; the final run follows temporary-root canonicalization.
The shared desktop was left to Photo Agent's native UI runner until it moved to
unit tests. FTP Sync native tests ran without browser activity.

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/continuation-tests \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSyncUISmokeTests \
  -destination 'platform=macOS' -derivedDataPath build/continuation-tests \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  DEVELOPMENT_TEAM=YOUR_LOCAL_TEAM \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testInterruptedImagePublicationReconcilesAndRetriesAcrossRelaunch \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testManagedInterruptedImagePublicationReconcilesAndRetriesAcrossRelaunch
Scripts/check-release-identity.sh
Scripts/check-security-baseline.sh
```

Logs: `/private/tmp/aftpsync-oct08-reconciliation-unit-final.log` and
`/private/tmp/aftpsync-oct08-reconciliation-native.log`. Result bundles:

- `build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.08_17-27-05-+0200.xcresult`
- `build/continuation-tests/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.10.08_17-25-22-+0200.xcresult`

Retained fixture paths are available in each native test's recovery warning and
session artifacts. No fixture directories were deleted by the reconciliation.

This closes the narrow current-host generated-JPEG native reconciliation/retry
gap. Camera RAW/XMP native interruption, other publication boundaries, ordinary
sync stop/recovery, scoped conflict batches, macOS 14, VoiceOver, controlled
production performance, signed Release observation, and final-candidate checks
remain open. No final-candidate checklist result was entered or carried forward.
