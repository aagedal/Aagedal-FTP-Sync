# Current-source geocoding and People Library verification — 2026-09-15

Source: clean `14d4056ba71fdcc7b5778f2518596a10417b4c67` on
`codex/version-3-0-plan` before the runs. Host: arm64 macOS 27.0 (`26A428`),
Xcode 27.0 (`27A266a`). The tracked development candidate remains the older
`9f04fad` build and is not promoted by these results.

Named job areas (`eab4b9e`) can supply City and `{gps:city}` from a saved polygon;
the selected geocoder still resolves Country when needed. People Library schema 3
(`14d4056`) admits hash-declared upgrade-source crops and preserves them in exact
directory/ZIP32 import and re-export. The cross-app fixture uses a synthetic color
gradient, not a person's photograph. The affected selection covered the strict
settings and polygon tests, geocoding transfer/reprocessing integration, and schema
3 manifest/package lifecycle.

The focused command passed with exit 0: 44 executed, zero failures. The complete
application command passed with exit 0: 1,177 executed, 20 opt-in skips, zero
failures (1,157 passed). The opt-in cases include the pinned real-model proof,
large-tree benchmark, loopback transport/PHP fixtures, and million-record scale
test; this result does not convert their skips into passes.

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/v3-geofence-library-followup \
  -only-testing:AagedalFTPSyncTests/MetadataGeofenceTests \
  -only-testing:AagedalFTPSyncTests/MetadataGeocodingSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/PeopleLibraryManifestTests \
  -only-testing:AagedalFTPSyncTests/PeopleLibraryPackageServiceTests \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/v3-geofence-library-followup \
  -only-testing:AagedalFTPSyncTests CODE_SIGNING_ALLOWED=NO
```

`Scripts/check-security-baseline.sh` and `Scripts/check-release-identity.sh` each
passed with exit 0. The latter correctly reports the unchanged 2.9.2 build 37.
The unsigned arm64 Release build passed with exit 0 at this source:

```sh
xcodebuild build -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/v3-geofence-library-followup CODE_SIGNING_ALLOWED=NO
```

The built app is `build/v3-geofence-library-followup/Build/Products/Release/AagedalFTPSync.app`.
Its executable SHA-256 is
`3b327aec675cebf0c29167b5ae7c609803b6c6a2eba03d65191c3b50ae1ef199`.
Logs and `.xcresult` bundles are retained under ignored `build/` paths. The first
focused command stopped before compilation with exit 74 because default sandbox
access denied Xcode's external compiler/package caches; the same focused command
passed after normal cache access was granted. The first transport-script attempt
stopped before server startup because system Python lacked the pinned packages;
the project benchmark environment has `paramiko 5.0.0` and `pyftpdlib 2.2.0`.

The subsequent disposable localhost FTP/FTPS/SFTP run used that environment
and passed with exit 0: all 16 opt-in transport cases passed. It covered the
late and mid-processing RAW companion cases, decodable JPEG/valid XMP metadata
delivery, changed-source removal protection, certificate rejection and grouped
publication rollback. The script also checked its fault fixtures and staging
cleanup before returning success. The first FTP cleanup test took 60.675 seconds;
this run is correctness evidence, not a delivery-latency budget result. Its ignored
output is `build/v3-current-remote-transport.log` and the test result bundle is
under `build/v3-geofence-library-followup/Logs/Test/`.

```sh
AFTPSYNC_TEST_DERIVED_DATA=build/v3-geofence-library-followup \
  build/3.0-benchmark-venv/bin/python Scripts/run-remote-transport-tests.py
```

This is source/build verification. A signed/native UI run, VoiceOver, supported
macOS 14 execution, production model identity and real-face calibration, camera
RAW/external-reader acceptance, the complete enriched performance matrix and a
signed 3.0 candidate remain open.

Companion contract follow-up: the adjacent Photo Agent checkout was clean at
`de8884440bcf391c5c837e841348c1ca08f512aa` and remained unchanged. Its
focused `KnownPeopleLocalStoreSnapshotBuilderTests` ran from an isolated DerivedData
path in this FTP Sync workspace and passed all 14 Swift Testing cases in one suite,
including “Opt-in crops round-trip through schema 3 ZIP and directory packages.”
The XCTest summary for that run says zero tests because these cases use Swift
Testing; the Swift Testing result in `build/v3-photo-agent-schema3-contract.log`
is the relevant count. The command passed with exit 0:

```sh
xcodebuild test -project '/Users/truls.aagedal/Developer/Aagedal-Photo-Agent/Aagedal Photo Agent.xcodeproj' \
  -scheme 'Aagedal Photo Agent Tests' -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/v3-photo-agent-schema3-contract \
  -disableAutomaticPackageResolution \
  '-only-testing:Aagedal Photo Agent Tests/KnownPeopleLocalStoreSnapshotBuilderTests' \
  CODE_SIGNING_ALLOWED=NO
```

The Photo Agent case creates its own crop, so this verifies the companion's
schema 3 producer/reader lifecycle but does not yet prove that both apps exchange
the identical real package through their native UIs. A module-name filter retry
was rejected by Xcode with exit 70. An unnecessary broad-target retry was
interrupted with exit 130 and is not counted as a suite pass; the companion test
host is no longer running. `security find-identity -v -p codesigning` reports
zero valid identities on this host, so production signing remains unavailable.
