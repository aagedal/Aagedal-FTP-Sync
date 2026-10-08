# M5 independent saved processing actions — 2026-09-19

Development source: clean base `b761977` plus the code, tests and documentation
committed with this report. Host: arm64 macOS 27.0 (`26A428`), Xcode 27.0
(`27A266a`). Version remains 2.9.2 (37). Candidate identity and private human
acceptance results are unchanged; no local results JSON was present.

## Changes

The job editor now presents Preview Saved Metadata and Reprocess Saved Files in
a shared Saved metadata processing section. Either an enabled schedule, enabled
geocoding or configured recognition admits these actions. Unsaved edits, missing
recognition prerequisites, a busy job, external-writer suspension and unsupported
destinations still prevent execution. Changing the job or draft closes pending
confirmation and preview results and cancels in-flight preview work. Preview uses
the existing saved-job resolver and captured recognition context.

Metadata Programming also admits independent geocoding and recognition for
reprocessing. The missing-original-arrival restriction applies only when a
schedule is enabled. Runtime, destination, busy-state and persistence checks
remain in place. The programming preview retains its intentional unsaved schedule
behavior; use the new saved processing section to preview independent settings.

Processing receipts now identify the actual SwiftMediaMetadata 3.0.1 writer and
offline geocoder runtime. The serialized geocoding policy identifier remains at
its original value so existing version-3 jobs still decode; policy and runtime
identity are explicitly distinct. A runtime upgrade makes prior receipts stale
for explicit reprocessing, without triggering retransfers during ordinary polling.

## Verification

The focused selection passes 86 tests with no failures or skips:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/MetadataProgrammingCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/MetadataGeocodingSettingsTests \
  -only-testing:AagedalFTPSyncTests/OfflineMetadataGeocodingProviderTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/MetadataGeocodingPreviewTests \
  CODE_SIGNING_ALLOWED=NO
```

Log: `build/v3-independent-actions.log`. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_17-45-55-+0200.xcresult`.
The initial sandboxed invocation could not access compiler/SwiftPM caches; its
approved retry passed. The added admission test covers standalone geocoding,
face-only and combined processing, missing runtime, enabled-schedule arrival
restrictions and bidirectional rejection.

After removing unused view arguments, a further focused regression checks the
actual writer dependency digest in a transfer receipt, decodes a simulated old
receipt, proves dependency staleness, observes an idle ordinary poll, and refreshes
the receipt through explicit reprocessing without changing already-enriched bytes.
Its command uses the same build settings with
`-only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests/testWriterUpgradeInvalidatesReceiptWithoutAutomaticRetransfer`.
Exit 0: one test passed with no failures or skips.
Log: `build/v3-writer-receipt.log`. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_17-47-03-+0200.xcresult`.

Security baseline, current release identity, string-catalog JSON validation and
`git diff --check` pass.

## Remaining gates

No native UI observation was performed while the separate Photo Agent and Media
Player tasks were active on the shared desktop. The shared-section layout,
keyboard/VoiceOver interaction and actual combined/standalone workflows still
need native verification. Generated-image/injected recognition evidence does not
replace camera RAW, authorized real-face calibration, supported-OS or signed
candidate acceptance. No milestone or checklist case is marked complete.
