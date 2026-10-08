# M5 saved preview and independent reprocessing — 2026-09-19

Development source: clean base `0b8eeeb` plus the code, tests, localization and
documentation committed with this report. Host: arm64, macOS 27.0 (`26A428`),
Xcode 27.0 (`27A266a`). Version remains 2.9.2 (37). The development candidate
and private acceptance results are unchanged; no local results JSON was present.

## Changes

The geocoding settings preview previously passed only automation, geocoding and
the raw saved file filter. Reprocessing also uses recognition and resolves the
programming history's filename prefixes. This could omit names from the preview,
leave a `{persons}` caption incomplete, or skip programming-filtered files.

A saved-job preview entry point now carries all three processing settings,
the persisted time zone, one captured recognition context and the historical
programming filter into the existing resolver. It retains disabled schedules.
The settings UI captures the store's admitted context, blocks saved actions when
recognition prerequisites are missing, and explains that reprocessing includes
enabled recognition. Its cancellation forwarding and request identity guards
remain in place.

The reprocessing engine's entry guard also incorrectly required a schedule or
geocoding even though the remaining pipeline supported recognition independently.
It now admits a configured recognition stage after the existing runtime guard.

## Verification

Exit 0, 80 tests, zero failures or skips:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataPreviewTests \
  -only-testing:AagedalFTPSyncTests/MetadataGeocodingPreviewTests \
  -only-testing:AagedalFTPSyncTests/MetadataExistingPreviewTests \
  -only-testing:AagedalFTPSyncTests/MetadataProgrammingCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

Log: `build/v3-saved-processing.log`. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_16-55-17-+0200.xcresult`.
App: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.
The final confirmation wording and matching string-catalog key were refined
after this run; those text-only changes were reviewed and JSON-validated.

New cases verify:

- A generated JPEG resolves `Oslo: Existing Person, Preview Person`, City/Country,
  recognition evidence and merged names without changing bytes. Historical
  programming prefixes admit that file and exclude an unrelated JPEG.
- Independent recognition leaves a disabled saved schedule disabled.
- A missing recognition context rejects the saved preview before folder access
  or provider invocation.
- Face-only reprocessing previews without writing, publishes Person Shown and
  Keywords, preserves the modification date, creates a complete receipt, and
  repeats with a disabled schedule without rewriting the image. No source files
  are required for this independent local operation.

An initial test expected the first repeat of a destination-only file to report
an identical source receipt. Without prior source signatures, the fallback
source evidence is the destination's pre-write size/date, so that expectation
was incorrect after the metadata write changed its size. The corrected test
requires a successful skipped outcome, a complete receipt and identical bytes;
it does not claim that recognition inference was skipped.

The first sandboxed build could not access compiler/SwiftPM caches; the approved
retry passed. Security baseline, current release identity, string-catalog JSON
validation and `git diff --check` pass.

## Remaining gates

These fixtures use generated JPEGs and injected location/face services, not
authorized real-face calibration or camera RAW. No desktop interaction was
initiated while Photo Agent's separate task was active. Native combined preview,
standalone face-only UI actions, supported-OS execution, production recognition
acceptance and signed candidate checks remain open. No checklist or milestone
was marked complete.
