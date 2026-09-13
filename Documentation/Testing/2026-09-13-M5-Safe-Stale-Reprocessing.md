# M5 safe stale/incomplete reprocessing

Date: 2026-09-13

Source: `524410afd8e8e32900f2329a05465397b5c14f65`

Environment: Apple silicon, macOS 27.0 (26A428), Xcode 27.0

Candidate status: development only; not ready for user acceptance

## Implemented

- Added an explicit reprocessing filter with **Stale or incomplete files** as the
  application default and **All matching files** as the deliberate broad option.
- Routed the newest durable per-path audit outcome from `AppStore` into the engine.
  A current complete receipt is re-recorded without rewriting its destination.
- Re-evaluate a file when source, settings or processing dependencies changed, or
  when the newest outcome has no complete receipt.
- Compare the current destination content with its last complete output digest
  before applying either filter. If the source is unchanged and the destination
  digest differs, preserve the destination and report an edit conflict. This guard
  also applies to **All matching files** and wins when settings changed at the same
  time. A changed source remains eligible, so a legitimate source resend is not
  mistaken for a destination edit.
- Added the selected filter and conflict-preservation rule to the confirmation UI,
  and the number of preserved edit conflicts to the completed-run summary. The
  detailed per-file reason remains available in the metadata audit trail.

## Verification

The affected regression selection passed 167 tests with zero failures:

```text
xcodebuild test -scheme AagedalFTPSync -destination 'platform=macOS' \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/MetadataAuditTests \
  -only-testing:AagedalFTPSyncTests/FTPListingTests \
  -only-testing:AagedalFTPSyncTests/LocalSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/MetadataGeocodingSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/MetadataFaceRecognitionSettingsTests \
  -only-testing:AagedalFTPSyncTests/DownloadNamingTests \
  CODE_SIGNING_ALLOWED=NO
```

This includes new focused coverage for current-receipt skipping, settings staleness,
combined settings/output conflicts, source resend classification, content preservation,
and existing transactional concurrent-edit protection. A separate four-test selection
covering the three original filter cases plus UI confirmation copy also passed.

The unsigned Release configuration built successfully. Its warnings were in the
vendored Citadel/swift-nio-ssh sources, plus the expected AppIntents extraction notice;
no warning originated in the changed app files. `Scripts/check-security-baseline.sh`
also passed.

An earlier combined run of the full `MetadataProgrammingCoordinatorTests` class
encountered its existing asynchronous preview-test instability: two preview assertions
failed and the replacement-preview test stalled until the run was interrupted. The
changed reprocessing presentation test passed in that run and alone. This is not claimed
as a clean pass for that whole class and remains part of broader candidate stabilization.

## Remaining boundary

This slice does not provide a preflight list/count before starting the scan, a UI action
for resolving an edit conflict, or a supported-OS/native end-to-end acceptance pass.
Legacy destinations with no receipt are intentionally treated as incomplete rather than
silently bootstrapped from destination evidence. Face-runtime production wiring,
performance tuning and the remainder of M5/M6 are unchanged.
