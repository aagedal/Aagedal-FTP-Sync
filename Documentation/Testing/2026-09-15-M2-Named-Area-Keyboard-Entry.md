# Named-area keyboard entry — 2026-09-15

Test source: clean base `45af507` plus the one-file
`MetadataGeofenceEditorView.swift` diff recorded with this report. Branch:
`codex/version-3-0-plan`. Host: arm64 macOS 27.0 (`26A428`), Xcode 27.0.
The tracked development candidate remains the older `9f04fad` build.
The exact changed app code is committed as `f282dc3`.

The job's Named Areas editor previously placed outline corners only through
map clicks. It now exposes latitude/longitude entry and an Add Corner action,
plus an ordered list of editable coordinates. The existing map path remains
available. Invalid or duplicate new coordinates cannot be appended; the saved
area still passes the strict polygon validator. The text controls expose
corner-specific accessibility labels and identifiers for a later native
keyboard/VoiceOver check.

The Debug `build-for-testing` command passed with exit 0, compiling the app and
test target at this change. A focused model and local integration selection
passed with exit 0: 18 executed, zero failures. Both commands used the existing
`build/v3-geofence-library-followup` DerivedData path and
`CODE_SIGNING_ALLOWED=NO`; ignored output is retained in
`build/v3-geofence-keyboard-build.log` and
`build/v3-geofence-keyboard-focused.log`.

```sh
xcodebuild build-for-testing -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/v3-geofence-library-followup CODE_SIGNING_ALLOWED=NO

xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/v3-geofence-library-followup \
  -only-testing:AagedalFTPSyncTests/MetadataGeofenceTests \
  -only-testing:AagedalFTPSyncTests/MetadataGeocodingSyncIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

The shared desktop was occupied by other active project work, so no actual
named-area editor interaction, keyboard path or VoiceOver pass is claimed.
Observe corner entry/editing, invalid input, area save/reopen and resulting
City/`{gps:city}` preview in the isolated native QA app before closing this
accessibility gate. The production version/build and feature defaults remain
unchanged.
