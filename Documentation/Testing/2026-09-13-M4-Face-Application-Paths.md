# M4 admitted face-recognition application paths

Date: 2026-09-13

Source: `cdfd88a`

Environment: Apple silicon, macOS 27.0 (26A428), Xcode 27.0

Candidate status: development only; not ready for user acceptance

## Implemented

- Added one immutable recognition context that binds an admitted analysis service,
  people-library core revision, gallery, runtime revision and calibrated-policy
  revision for the lifetime of a processing operation.
- Regular and early transfer plus explicit local reprocessing can now run that
  admitted context. The production default remains unavailable and continues to
  reject face-enabled jobs before opening endpoints.
- Accepted names are appended losslessly to Person Shown and, when selected, to
  Keywords. Existing Person Shown values and accepted names share `{persons}`
  expansion without parsing names as template syntax.
- Recognition failures remain incomplete, produce no complete fingerprint and keep
  the existing source-removal safety behavior. Typed, redacted recognition evidence
  is attached to transfer and reprocessing audit entries.
- Complete fingerprints now include people-library core, runtime and acceptance-policy
  revisions. A changed admitted library therefore makes a prior receipt stale even
  when the source and job settings are unchanged.
- Face-only RAW processing uses the generated-sidecar namespace and processed-folder
  admission rules already used by scheduled metadata and geocoding.

## Verification

The focused four-class selection and a broader nine-class selection passed. The
broader selection contains 156 declared tests and covers activated transfer/reprocess,
the bounded analysis service, face-name writing, processing resolution/audit,
geocoding integration, local publication/recovery, fingerprints and saved settings.
New integration cases prove accepted-name publication with redacted durable evidence
and changed-library stale reprocessing.

`Scripts/check-security-baseline.sh` passed. An unsigned Release build completed.
Warnings were from the vendored Citadel/swift-nio-ssh sources; the changed app files
did not emit a warning.

A full-suite attempt did not report a test failure, but Xcode remained blocked while
finalizing the test runner. It was interrupted after 150 seconds and is not counted as
a pass. This is consistent with the already recorded test-runner/preview instability;
the bounded affected selections terminate cleanly.

## Remaining boundary

This is production-path logic with explicit dependency injection, not production
admission. A dedicated signing key, fixed HTTPS distribution hosts, identity-bound
startup construction, calibrated policy, preview/UI wiring, authorized real-face
accuracy fixtures and measured resource-cap tuning remain open. No recognition feature
is enabled by default, and no native GUI or supported-OS acceptance case advanced.
