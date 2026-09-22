# Native Metadata Programming image recovery — 2026-09-22

The focused native UI regression now follows a generated, decodable JPEG through
Metadata Programming's recovery review, explicit reconciliation, preflight,
publication, and relaunch. It runs with both an ordinary destination and managed
`Synced Files`. The isolated fixture keeps the job disabled and uses a named
geofence, so the City write is deterministic without a network request.

Each case verifies that the retained transaction blocks publication, cancellation
leaves image bytes untouched, a later preflight reports one ready image without
writing it, and explicit publication succeeds. ImageIO independently reads the
published IPTC City as `Recovery Venue`. The source image and destination
modification date remain unchanged; a relaunch reports zero ready files and
preserves the published bytes.

## Verification

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/v3-programming-image \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testProgrammingPublishesRecoveredImageAndPreservesItAcrossRelaunch \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testManagedProgrammingPublishesRecoveredImageAndPreservesItAcrossRelaunch
```

Both selected signed native tests passed with zero failures in 77.289 seconds.
Log: `build/v3-programming-image-ui-both.log`. Result bundle:
`build/v3-programming-image/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.22_23-31-25-+0200.xcresult`.

This exercises JPEG publication after a retained text-fixture transaction. It
does not exercise an interrupted JPEG or RAW/XMP transaction, an edited-output
conflict in the native Programming sheet, camera RAW, VoiceOver, or a complete UI
suite on a release candidate.
