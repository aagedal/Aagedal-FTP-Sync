# M5 legacy receipt bootstrap boundary

Date: 2026-09-13

Source: `c8d003a39d519264ea6ab6d69a8feeb83482a9df`

Environment: Apple silicon, macOS 27.0 (26A428), Xcode 27.0

Candidate status: development only; not ready for user acceptance

## Implemented

- A legacy destination without a processing receipt can acquire a complete no-write
  receipt only when the job has a durable source signature from a prior successful
  publication. A current source listing alone is not treated as ownership evidence.
- A missing or changed saved source signature leaves an already-complete destination
  untouched and reports it as incomplete for receipt tracking.
- Failed or partially resolved audit outcomes are no longer accepted as complete
  receipts, including fingerprints written by an earlier development build.
- A current source listing is authoritative when a RAW companion has been removed;
  stale saved companion evidence no longer hides that source change.
- Explicit reprocessing that publishes a change still records its new output receipt.
  Existing receipt-based edit protection and the path-bound conflict action remain in
  force.

## Verification

The focused activated-metadata suite passed 16 tests with zero failures. New cases
cover a safe legacy bootstrap, refusal without durable source evidence, incomplete
resolution without a receipt, and removal of a source RAW companion.

The broader M5 selection covered 174 declared tests across these seven classes and
completed successfully:

```text
xcodebuild test -quiet -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/MetadataAuditTests \
  -only-testing:AagedalFTPSyncTests/FTPListingTests \
  -only-testing:AagedalFTPSyncTests/LocalSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/MetadataGeocodingSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/MetadataFaceRecognitionSettingsTests \
  -only-testing:AagedalFTPSyncTests/DownloadNamingTests \
  CODE_SIGNING_ALLOWED=NO
```

`Scripts/check-security-baseline.sh` passed. An unsigned Release build succeeded.
Warnings came from vendored Citadel/swift-nio-ssh sources; no warning came from the
changed app files.

## Remaining boundary

No native GUI or supported-OS case advanced in this slice. Files without durable
source evidence deliberately remain incomplete rather than gaining a synthetic
receipt. The full path/recovery/performance matrix, production face integration,
supported-OS evidence and M6 candidate checks remain open.
