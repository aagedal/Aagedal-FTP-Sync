# M5 reprocessing snapshot validation — 2026-09-19

Development source: clean base `1b05379` plus the source, tests and documentation
committed with this report, on `codex/version-3-0-plan`. Host: arm64 macOS 27.0
(`26A428`), Xcode 27.0 (`27A266a`). App identity remains 2.9.2 (37).
No human results JSON was present; the earlier development candidate is unchanged.

## Change

Reprocessing resolved metadata against private copies, but no-change paths could
record a complete receipt after a destination edit during asynchronous resolution.
The engine now compares the destination primary and existing RAW companion with
the inspected bytes before issuing receipts or preparing publication. An unexpected
new RAW sidecar also rejects the snapshot. Mismatches produce a failed per-file
outcome without a complete fingerprint and preserve the destination. Existing
transactional write checks still protect the subsequent publication interval.
Read-only checks are point-in-time validation, not exclusion of external writers.

## Verification

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/MetadataGeocodingSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/MetadataProgrammingCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

Exit 0: 93 tests, zero failures. Security, current-identity and whitespace checks
pass. A disposable RAW/XMP fixture mutates the destination headline during an
injected geocoder lookup while preserving size and timestamp. The lookup returns
already-applied City/Country values. Both filters and preflight/write modes reject
a complete receipt and preserve the edit. A local snapshot regression separately
checks a new companion and equal-length primary edits without filesystem mutation
by validation. RAW bytes are synthetic; no real-model or camera-RAW claim is made.

The initial sandboxed invocation could not access compiler caches; the approved
retry passed. Final log: `build/v3-reprocess-snapshot.log`. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_20-32-26-+0200.xcresult`.

## Remaining acceptance

Other product tasks were active; verification used isolated non-UI fixtures.
Native conflict/retry observation, supported-OS runs, real-face calibration,
camera RAW and signed release-candidate validation remain open. No milestone
or manual checklist case was marked complete.
