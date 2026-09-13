# M5 reprocessing preflight and conflict resolution

Date: 2026-09-13

Source: `a50853ba8d4873da833545fd3ae91f9390fbf7ba`

Environment: Apple silicon, macOS 27.0 (26A428), Xcode 27.0

Candidate status: development only; not ready for user acceptance

## Implemented

- Reprocessing now begins with a no-publication preflight that uses the same source,
  settings, dependency and output-fingerprint evaluation as the eventual run.
- The confirmation dialog reports files scanned, ready to update, skipped, incomplete
  or failed, and outputs edited since their latest complete receipt.
- The ordinary confirmation action preserves edited outputs. A separate destructive
  action can explicitly include only the edited paths identified by that preflight.
- Conflict approval is bound to that exact path set. An output edited after preflight
  remains protected when the run rechecks the destination.
- Cancelling a preflight cannot publish files or surface a late ready result. The
  eventual run repeats all checks and retains transactional destination matching.

## Verification

The M5 regression selection passed 170 tests with zero failures:

```text
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
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

A separate focused selection passed 15 tests, covering the 14 activated metadata
integration cases and the reprocessing confirmation presentation test. New cases prove
that preflight does not publish a settings change, an explicitly included edit can be
processed, and a new edit made after preflight remains untouched.

`Scripts/check-security-baseline.sh` passed. An unsigned Release build succeeded. Its
warnings came from vendored Citadel/swift-nio-ssh sources and the expected AppIntents
extraction notice; no warning came from the changed app files.

One earlier attempt to run the entire metadata-programming coordinator class reached
its existing replacement-preview stall after its preceding tests passed. The run was
interrupted and is not counted as a pass. The isolated changed presentation test passed.

## Remaining boundary

This is automated and build evidence, not an observed native GUI pass. Legacy
destinations without a receipt remain incomplete rather than being bootstrapped from
untrusted destination evidence. The full M5 path/recovery/performance matrix,
supported-OS validation, face-runtime production wiring and M6 release checks remain
open.
