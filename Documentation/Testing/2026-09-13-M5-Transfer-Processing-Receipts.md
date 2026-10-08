# M5 transfer processing receipts

Date: 2026-09-13

Source revision: `3c61e4d8b124cf51f1aa970267f52537d9fca94c`

Environment:

- macOS 27.0 (26A428), Apple silicon (`arm64`)
- Xcode 27.0 (27A266a)
- App version remains 2.9.2 (37); this is development evidence, not a release candidate

## Scope

Complete processing outcomes now receive the same strict schema-1 fingerprint in
regular transfer and completed-directory early-delivery paths as they do in explicit
reprocessing. The fingerprint is constructed over the staged primary/sidecar output
group before publication. A provenance failure falls back to the intact source group;
in particular, a generated RAW sidecar is cleared before fallback and cannot be
published without its receipt.

Complete no-op outcomes also receive receipts. This covers transfers where existing
metadata is preserved and explicit reprocessing where the programmed values are already
present, without rewriting the destination. Incomplete resolution and failed work still
cannot receive a fingerprint.

`MetadataAuditRepository` now exposes the newest outcome per job/path and a derived
complete-receipt index. A newer failed or incomplete entry intentionally supersedes an
older fingerprint, preventing future filtering from resurrecting stale success evidence.

## Verification

This affected selection passed with exit status 0. The seven selected classes contain
170 declared test methods and cover the new regular-transfer, completed-directory early
transfer, already-applied reprocessing and latest-outcome index cases, plus surrounding
audit, local sync, geocoding, preview/recovery and download-naming behavior.

```sh
xcodebuild test -quiet \
  -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync \
  -destination 'platform=macOS' \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/MetadataAuditTests \
  -only-testing:AagedalFTPSyncTests/FTPListingTests \
  -only-testing:AagedalFTPSyncTests/LocalSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/MetadataGeocodingSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/MetadataPreviewAndRecoveryTests \
  -only-testing:AagedalFTPSyncTests/DownloadNamingTests \
  CODE_SIGNING_ALLOWED=NO
```

The dependency guard also passed:

```sh
Scripts/check-security-baseline.sh
```

Candidate JSON parsing passed, and the checklist persistence/authorization suite passed
all 5 tests after being run with permission to bind its disposable `127.0.0.1` server.

The worktree was clean at the recorded source revision. No installed app, user data,
source photos, calendar server, model distribution or companion checkout was changed.

## Open gates

The latest-outcome index is not yet connected to a user-selectable incomplete/stale
reprocessing filter. Computing staleness must retain the four independent dimensions:
source evidence, settings, runtime dependencies and exact output content. An output
content mismatch is a destination conflict and must not be overwritten by an ordinary
stale filter. Legacy destination bootstrap evidence still needs replacement by durable
source evidence. Face runtime/library revisions await production application-path wiring.
The full M5 validation matrix, performance work, supported-OS checks and native UI
verification remain open.
