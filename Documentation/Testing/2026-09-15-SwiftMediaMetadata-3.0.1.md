# SwiftMediaMetadata 3.0.1 adoption

Date: 2026-09-15  
Implementation commit: `5944d5bbb47f5bbf5afa3a12d4a0b60849464ed2`  
Host: macOS 27.0 (`26A428`), Apple silicon

## Decision and provenance

FTP Sync and its standalone compatibility probe now pin SwiftMediaMetadata 3.0.1
exactly. The official `3.0.1` tag resolves to
`8662054299a3e13c49c65f74c564360559d1bf7f`.

The package manifest declares macOS 13, below FTP Sync's unchanged macOS 14 target.
Version 3 retains the write and synchronization entry points used by this app. Its
documented source-breaking additions affect exhaustive switches over new XMP/photo
metadata enum cases; the FTP Sync source has no such switches. Version 3.0.1 fixes
top-level Sony RTMD discovery so it does not copy complete `mdat` payloads into memory,
plus package-fixture and release-packaging issues.

This supersedes the initial-development decision to stay on 2.0.0 while the major
release was still being evaluated. It does not substitute for a macOS 14 runtime pass
or the final real-image/external-reader matrix.

Official source:

- `https://github.com/aagedal/SwiftMediaMetadata/releases/tag/3.0.1`
- tag commit: `8662054299a3e13c49c65f74c564360559d1bf7f`
- package license remains GPL-3.0; GeoNames attribution remains required

## Verification

Standalone compatibility probe:

```text
swift run MetadataCompatibilityProbe
PASS — SwiftMediaMetadata 3.0.1
PASS — offline Oslo/Norway and Norwegian localization
PASS — 50 km ocean cutoff
PASS — embedded JPEG and XMP sidecar City/Country/Person Shown
PASS — Unicode and unrelated caption preserved
PASS — decoded JPEG pixels identical after the metadata rewrite
```

Complete application suite:

`build/v3-swift-media-301-nonui/Logs/Test/Test-AagedalFTPSync-2026.09.15_00-26-18-+0200.xcresult`

- 1,146 total
- 1,130 passed
- 0 failed
- 16 opt-in skips

Complete signed UI suite, successful retry:

`build/v3-swift-media-301-full-ui/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.15_00-35-03-+0200.xcresult`

- 18 passed, 0 failed, 0 skipped
- no application crash
- seven existing QoS diagnostics and one existing SwiftUI view-update diagnostic

The first signed attempt did not execute an application test because macOS timed out
enabling XCTest automation mode:

`build/v3-swift-media-301-full-ui/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.15_00-32-56-+0200.xcresult`

- 0 application tests passed or failed
- runner initialization error: timed out while enabling automation mode
- the already-built `test-without-building` retry above passed the complete suite

Additional checks:

```text
Scripts/check-security-baseline.sh
PASS — Security dependency baseline verified.

Scripts/check-release-identity.sh
PASS — Release identity verified for 2.9.2 (build 37).

python3 Scripts/test-3.0-checklist.py
PASS — 5 passed.

xcodebuild build -scheme AagedalFTPSync -configuration Release \
  -destination 'platform=macOS,arch=arm64' ... CODE_SIGNING_ALLOWED=NO
PASS
```

Release output:

`build/v3-swift-media-301-release/Build/Products/Release/AagedalFTPSync.app`

The executable is arm64 with SHA-256
`27df0127d9ff4cdcf598cf9df2bfaeb06548b40e8ccc129288f6ab06557698dc`.
The bundle remains version 2.9.2 (37), so this is development evidence rather than a
beta or release candidate.
