# 3.0 interchange and scoped recovery follow-up — 2026-09-23

Source: `4fb18f0` plus the changes committed with this report. Host: macOS
27.0 (26A428), Xcode 27.0 (27A266a). These are development tests, not a
signed Release candidate. Test folders were disposable; production jobs and
private People Libraries were not used.

## Results

- Copied Photo Agent commit `45c5ed1`'s nonprivate schema 2 golden People
  Library fixture byte for byte. FTP Sync imports it, exports every package
  file unchanged, and reimports it into a separate repository. The new
  `PhotoAgentPeopleLibraryInterchangeTests` passes 1/1. This establishes a
  producer-authored format fixture, not a same-package native UI exchange or
  schema 3 crop interoperability.
- Native Metadata Programming JPEG recovery tests now also enter the clip
  action while a transaction is retained. Both ordinary and managed output
  tests show the recovery path, withhold the publish action, and preserve the
  image/source bytes, image modification date, and retained transaction after
  cancellation. They then continue their existing reconciliation, publication,
  and relaunch assertions. Focused signed UI tests pass 2/2. The seeded image
  does not match the clip, so scoped publication and RAW/XMP remain open.
- Recovery admission skips impossible unrelated hidden names before Swift
  string allocation. It still scans the directory afresh at every boundary,
  checks cancellation in 256-entry batches, and applies the complete predicate
  to possible recovery names. The late-recovery regression now includes 600
  unrelated hidden and 600 ordinary names; two focused tests pass. This is a
  narrow allocation reduction, not a measured release-scale speedup.

Commands and local evidence:

```sh
xcodegen generate --spec project.yml
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/v3-full-nonui-sep22 CODE_SIGNING_ALLOWED=NO \
  -only-testing:AagedalFTPSyncTests/PhotoAgentPeopleLibraryInterchangeTests
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/v3-full-ui-sep22 \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testProgrammingPublishesRecoveredImageAndPreservesItAcrossRelaunch \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testManagedProgrammingPublishesRecoveredImageAndPreservesItAcrossRelaunch
```

Both displayed commands exit 0. The focused recovery tests run with a
separate DerivedData directory and also pass 2/2. Logs are at
`build/v3-photo-agent-interchange-test.log` and
`build/v3-scoped-image-ui-test.log`; Xcode result bundles remain under the
corresponding ignored DerivedData directories. The first unprivileged
interchange attempt ended before compilation because Xcode's caches were
outside the workspace sandbox; the permitted retry passed.

Remaining related gates: a producer-generated schema 3 package exchanged
through both native apps, matching clip publication, camera RAW/XMP and
external-reader integrity, native interrupted image reconciliation, and
controlled release-scale performance.
