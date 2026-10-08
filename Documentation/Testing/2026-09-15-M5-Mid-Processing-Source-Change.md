# M5 source change during metadata processing — 2026-09-15

Code commit: `97a072302cd07fda4b794b56310f1532088ccff3` on
`codex/version-3-0-plan`, from clean base `bb010d010456a56e4d8b279b73d276d5f33e6096`.
Host: arm64, macOS 27.0 (`26A428`), Xcode 27.0. This remains a 2.9.2 (37)
development source; no versioned release candidate was built.

An injected geocoder changes a disposable RAW XMP source companion after the
engine has read its snapshot. The replacement headline has the same byte count
as the original, and the test restores the original modification time. Before
the fix, source removal correctly failed but the processed folder already held
the stale RAW/XMP copy. The failing test observed both processed files there.

The engine now compares every source file in a processed group with its downloaded
snapshot before publishing any processed copy. Final verified source removal
continues to check for changes after this comparison. The corrected test observes
an empty processed folder, retained source pair, and a successful retry that
publishes the changed headline and opaque RAW bytes before removing the source.
The normal destination may already contain the first output after the failed
run; the processed publication is the boundary this guard addresses.

The test ran at `bb010d0` plus the reviewed two-file diff that became `97a0723`.
The focused equal-size/equal-time interval passed 1/1 with exit 0:

`xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync -destination 'platform=macOS' -derivedDataPath build/v3-source-mutation -only-testing:AagedalFTPSyncTests/MetadataGeocodingSyncIntegrationTests/testSourceSidecarChangedDuringGeocodingDoesNotPublishStaleProcessedPair CODE_SIGNING_ALLOWED=NO`

The two affected integration classes passed 65/65, zero failures, exit 0, after
the engine change and before strengthening the fixture to equal-size/equal-time:

`xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync -destination 'platform=macOS' -derivedDataPath build/v3-source-mutation -only-testing:AagedalFTPSyncTests/MetadataGeocodingSyncIntegrationTests -only-testing:AagedalFTPSyncTests/LocalSyncIntegrationTests CODE_SIGNING_ALLOWED=NO`

Result bundles: `build/v3-source-mutation/Logs/Test/Test-AagedalFTPSync-2026.09.15_16-49-20-+0200.xcresult`
and `Test-AagedalFTPSync-2026.09.15_16-48-35-+0200.xcresult` in the same directory.
The earlier pre-fix result is the `16-46-56` bundle. Logs remain in ignored
`build/` files. `Scripts/check-security-baseline.sh`,
`Scripts/check-release-identity.sh`, and `git diff --check` passed.
The first sandboxed Xcode attempt could not access SwiftPM/Xcode caches; the
authorized cache-access retry ran. An initial fixture closure failed to compile
because it threw from a nonthrowing provider; the corrected fixture compiled.

This is synthetic RAW and generated XMP with an injected place provider. The
extra pre-publication source read needs an enriched-burst latency check. Remote
processed-source behavior, real camera RAW, native UI, external-reader integrity,
supported-OS coverage and the complete M5 matrix remain open.
