# M5 bounded fingerprint memory — 2026-09-19

Development source: clean base `07a2281c7ad8ba45eb77429a5c0a87514ce95560`
plus the implementation and regression tests committed with this report.
Host: arm64, macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`).
Version remains 2.9.2 (37); candidate identity and private acceptance results
are unchanged. No local results JSON was present.

## Finding and change

The shared processing fingerprint reader requested 1 MiB at a time, but
Foundation retained its autoreleased read buffers until the enclosing pool
drained. This made memory consumption grow with file size during preview,
transfer receipt construction, and reprocessing checks.

A local Foundation/CryptoKit probe hashed a disposable sparse 256 MiB file
inside one outer autorelease pool. The original reader increased peak resident
memory by 256.90625 MiB; draining each iteration's pool added no measurable
resident growth on the immediately following run. Both produced SHA-256
`a6d72ac7690f53be6ae46ba88506bd97302a093f7108472bd9efc3cefda06484`.
Elapsed times were 0.1042 and 0.0875 seconds respectively. The second read was
warm and followed the first in the same process: these timings and the zero
increment are diagnostic observations, not a cold/warm performance comparison
or a total-memory claim. Probe source is in ignored
`build/preview-hash-memory-probe.swift`.

Production hashing now drains an autorelease pool after each chunk. The
fingerprint format, SHA-256 input and chunk size are unchanged. Cancellation
is checked before any artifact processing, before opening each input, before
and after each read, and after EOF. A previously cancelled empty artifact list
now throws instead of returning a revision, and a missing file cannot mask
pre-existing cancellation with an I/O error.

## Verification

The durable `MetadataAuditTests` regression creates a disposable sparse 128 MiB
file, keeps an outer pool alive, and verifies retained resident growth remains
below 32 MiB. The measured growth was 3,096,576 bytes (about 2.95 MiB). A repeated
read returns the same fingerprint. Separate cancellation checks cover empty
artifact lists and missing inputs. The existing tests cover canonical ordering,
content changes, receipt persistence, and independent staleness dimensions.

Exit 0: 89 tests, zero failures or skips:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/MetadataAuditTests \
  -only-testing:AagedalFTPSyncTests/MetadataGeocodingPreviewTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataPreviewTests \
  -only-testing:AagedalFTPSyncTests/MetadataExistingPreviewTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/MetadataProgrammingCoordinatorTests \
  CODE_SIGNING_ALLOWED=NO
```

Log: `build/v3-fingerprint-memory.log`. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_16-16-45-+0200.xcresult`.
Test host: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.
The initial sandbox attempt failed to access SwiftPM/compiler caches; the
approved retry above completed normally.

`Scripts/check-security-baseline.sh`, `Scripts/check-release-identity.sh`
and `git diff --check` pass.

## Remaining gates

This measures hashing buffers, not decoded image/model memory or full delivery
performance. The fixture is synthetic, not a camera RAW. Controlled enriched
bursts, actual RAW/XMP/native workflows, macOS 14, face calibration, and signed
candidate verification remain open. No desktop interaction was initiated while
the separate Photo Agent task was active. No release milestone or checklist
acceptance was marked complete.
