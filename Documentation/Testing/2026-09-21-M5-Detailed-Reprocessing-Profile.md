# M5 detailed reprocessing profile — 2026-09-21

Source: `19c84fc` plus the diagnostic changes and records in this commit, on
`codex/version-3-0-plan`. Host: macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`),
arm64. Development identity: 3.0.0 (38). No private results JSON is present;
the historical candidate and checklist lanes are unchanged.

## Change

Extend opt-in local-session measurements to individual file lookup, snapshot
export, byte snapshot validation and matching publication. Validation/publication
measurements start after their fresh recovery admission, so intervals do not
nest. Normal sessions have no observer and do not read the measurement clock.
Paths and contents are never emitted. No processing or admission behavior changes.
The benchmark now reports every operation and asserts that only the publication
phase performs its 50 matching publications.

## Verification

```sh
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_BENCHMARK=1 \
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_SAMPLES=3 \
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

Log: `build/v3-reprocessing-detailed-profile.log`. Restricted compilation failed
on compiler-cache access; approved Xcode access allowed the test run.

Focused selection: 61 executed, 57 passed, four opt-in skips, zero failures;
exit 0. Security, development-identity and diff guards pass. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.21_17-13-51-+0200.xcresult`.
All 300 publications and 300 current-receipt skips retain byte/metadata/receipt
assertions across three samples at each background size.

## Measurements

Median seconds over three samples. Columns are independently aggregated.

| Background | Phase | Total | Listing | Recovery | Copy | Validate | Publish | Other |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | preflight | 0.3197 | 0.0007 | 0.0053 | 0.0143 | 0.0145 | 0.0000 | 0.2853 |
| 0 | publicationAndAudit | 0.5246 | 0.0007 | 0.0113 | 0.0155 | 0.0145 | 0.1764 | 0.3049 |
| 0 | currentReceiptRepeat | 0.1832 | 0.0007 | 0.0053 | 0.0143 | 0.0142 | 0.0000 | 0.1486 |
| 100000 | preflight | 4.1992 | 0.7914 | 2.2650 | 0.0165 | 0.0197 | 0.0000 | 1.0176 |
| 100000 | publicationAndAudit | 6.6898 | 0.8290 | 4.5420 | 0.0171 | 0.0206 | 0.2043 | 1.0364 |
| 100000 | currentReceiptRepeat | 4.0632 | 0.8663 | 2.2904 | 0.0172 | 0.0208 | 0.0000 | 0.8699 |

Every phase performs one listing, 75 snapshot copies and 50 byte validations.
Preflight/repeat perform 51 recovery checks; publication performs 101 checks and
50 transactions. There are zero individual file lookups in this workload.
Copying and byte validation are small costs here; recovery remains dominant.
The unmeasured remainder still includes filtering, collision reservations, source
evidence, hashing, metadata resolution/I/O and audit persistence.

## Limits and next actions

These are warm filesystem Debug measurements using a deterministic geocoder,
generated JPEGs and synthetic RAW with valid XMP. They do not measure production
face/geocoder workloads or establish a speedup or release-budget pass. Continue
fresh recovery-scan optimization without caching away admission checks, then
measure engine filtering/collision/evidence overhead. Native recovery, camera RAW,
real-face calibration, macOS 14 and final-candidate validation remain open.

Release inventory also confirms no valid signing identities via
`security find-identity -v -p codesigning` on this host. The milestone summary
now distinguishes current 3.0.0 (38) source from the older tracked candidate and
references the latest full non-UI result. No acceptance gate is closed here.
