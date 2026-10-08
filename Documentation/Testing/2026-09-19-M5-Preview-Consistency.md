# M5 preview consistency — 2026-09-19

Development source: clean base `e83bfae49704f23979e372eb39adc1703eba97a1`
plus the preview, regression-test and project-configuration changes committed with
this report. Host: Apple silicon, macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`).
Version remains 2.9.2 (37); no new release candidate or acceptance results.

## Behavior

Asynchronous enrichment preview now hashes the primary image and any RAW XMP
companion before reading metadata, then checks that revision after resolution and
assessment. Companion presence is part of the revision. A detected edit makes the
item `previewFailed`, clears its proposed and existing values, and asks the user
to refresh. Other files continue normally. Preview never writes to the input.
Content comparison catches persistent edits even when byte count and filesystem
modification time stay unchanged; this is not a filesystem lock or a promise to
detect a transient edit reverted before the final comparison.

Two regression cases inject edits during geocoding:

- A generated JPEG gets changed GPS with unchanged size and restored modification
  time. The stale result is rejected and no proposed/existing metadata is shown.
- A synthetic RAW's valid XMP gets changed GPS. The stale result is rejected; a
  fresh preview succeeds, preserving the RAW bytes and externally changed XMP.

The existing preview cases continue to cover no-clip/disabled schedules, read-only
behavior, preservation policies, missing GPS and corrupt files.

## Build repair

The recent app target rename left unit `TEST_HOST` and UI `TEST_TARGET_NAME`
pointing to `AagedalFTPSync`. Xcode stopped before compilation with “Could not
find test host.” Both Debug/Release configurations now name `Aagedal FTP Sync`.
`project.yml` uses that same app target in dependencies and scheme build/pre-action
references; the Swift module name and bundle identifiers remain explicit.

## Verification

Exit 0, 16 tests, zero failures:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/MetadataGeocodingPreviewTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataPreviewTests \
  -only-testing:AagedalFTPSyncTests/MetadataExistingPreviewTests CODE_SIGNING_ALLOWED=NO
```

Log: `build/v3-preview-consistency.log`. Result:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_13-41-05-+0200.xcresult`.
The initial sandbox attempt could not write required SwiftPM/compiler caches;
the approved cache-access retry exposed the test-host defect, now fixed.

UI-test target build-for-testing also exits 0 (`TEST BUILD SUCCEEDED`):

```sh
xcodebuild build-for-testing -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency CODE_SIGNING_ALLOWED=NO
```

Log: `build/v3-preview-ui-build.log`. This compiles UI tests but does not run them.

`xcodegen dump --type json`, `Scripts/check-security-baseline.sh`,
`Scripts/check-release-identity.sh` and `git diff --check` pass.

## Limits and next work

The content guard adds two streamed reads of each eligible preview input; large
camera-RAW preview performance still needs measurement. These fixtures use an
injected provider, generated JPEG and opaque RAW, with no real-face or online
service acceptance implied. Native UI observation was not performed; Photo
Agent's separate task was active, and no desktop interaction was initiated.
Supported-OS, calibration, native/camera-RAW, signed candidate and full release
matrix gates remain open. Candidate identity and private user results are untouched.
