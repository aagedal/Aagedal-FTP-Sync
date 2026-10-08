# M5 optimized reprocessing profile — 2026-09-21

Source: clean app/test revision `e7523ffa9eb6cd2b00063d4e906a4f29a671cd59`,
on `codex/version-3-0-plan`; only readiness documentation changed during the run.
Host: Apple silicon, macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`).
Development identity: 3.0.0 (38). No application or test code changed.

## Purpose and build boundary

The earlier detailed profile used Debug. This run checks whether recovery remains
dominant with Swift `-O` whole-module optimization. It uses Release configuration
with testability and inherited compilation conditions plus `DEBUG`, because
several existing hosted tests require DEBUG-only injected face-context APIs.
This is an optimized test build, **not a shipping Release candidate**.

The unmodified Release test attempt built the app but failed to compile the test
target against those unavailable APIs (exit 65). An initial flags override also
removed Swift package compilation conditions and failed package compilation
(exit 65). Preserving `$(inherited)` corrected that invocation. The successful
command does not change checked-in build settings or add test hooks to normal
Release builds. The initial restricted attempt failed on compiler-cache access;
approved Xcode access was used for the subsequent runs.

## Successful verification

```sh
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_BENCHMARK=1 \
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_SAMPLES=3 \
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG'
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
python3 Tools/verify_bundled_auraface.py source \
  AagedalFTPSync/Resources/Models/AuraFaceR100.mlpackage
python3 Tools/verify_bundled_auraface.py app \
  'build/v3-preview-consistency/Build/Products/Release/Aagedal FTP Sync.app'
git diff --check
```

61 tests executed: 57 passed, four opt-in skips, zero failures; exit 0.
Security, development identity, model source/app payload/license and diff checks
pass. The benchmark verifies 300 publications and 300 unchanged-receipt skips
across three samples at each background size, retaining metadata/byte/receipt
assertions. It uses 25 generated JPEGs and 25 synthetic RAW/valid-XMP pairs per
batch with deterministic geocoding and warm filesystem caches.

App: `build/v3-preview-consistency/Build/Products/Release/Aagedal FTP Sync.app`.
Executable SHA-256:
`026866d7a07b51aac75588a7484ce0adf3c4c6840cf788e8f39fe1a21a4c0c51`.
Result: `build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.21_17-47-12-+0200.xcresult`.
Logs: `build/v3-release-reprocessing-profile.log` (Release test compilation),
`build/v3-optimized-reprocessing-profile.log` (overridden package conditions),
and `build/v3-optimized-reprocessing-profile-inherited.log` (passing run).

## Measurements

Median seconds over three samples; each column is independently aggregated.

| Background | Phase | Total | Listing | Recovery | Copy | Validate | Publish | Other |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | preflight | 0.3915 | 0.0008 | 0.0081 | 0.0217 | 0.0213 | 0.0000 | 0.3396 |
| 0 | publicationAndAudit | 0.6455 | 0.0008 | 0.0157 | 0.0213 | 0.0201 | 0.2465 | 0.3406 |
| 0 | currentReceiptRepeat | 0.2009 | 0.0008 | 0.0080 | 0.0193 | 0.0200 | 0.0000 | 0.1531 |
| 100000 | preflight | 3.5924 | 0.6969 | 2.2188 | 0.0198 | 0.0275 | 0.0000 | 0.6540 |
| 100000 | publicationAndAudit | 6.9486 | 0.6532 | 5.3097 | 0.0203 | 0.0254 | 0.2665 | 0.6392 |
| 100000 | currentReceiptRepeat | 3.4396 | 0.6733 | 2.2720 | 0.0180 | 0.0241 | 0.0000 | 0.4729 |

Each phase performs one listing, 75 snapshot exports and 50 byte validations;
preflight/repeat retain 51 fresh recovery checks and publication retains 101.
No individual file lookups occur. All 50 transactions run only in publication.

Recovery remains dominant with optimization: median publication is 6.949 s,
including 5.310 s recovery and 0.653 s listing. This is not a demonstrated
speedup over the earlier 6.690 s Debug median: samples are unpaired and the host
is shared. Production model/provider work, cold/warm controlled conditions,
camera RAW, peak memory and release latency budgets remain unverified here.
Next investigate faster fresh recovery enumeration without caching admission,
and repeat matched configurations on a quiet host before claiming improvements.

## Readiness reconciliation

The readiness summary now reflects the bundled model instead of superseded
hosted distribution/installer requirements, credits user-confirmed Mac-to-Mac
sync, and records the latest full-suite total. Checklist cases `m0-003` and
`m4-001` still describe the removed installer; revise them together with a NEW
candidate identity before handoff. This run leaves the historical candidate and
all checklist lanes unchanged; no private results file is present.

`security find-identity -v -p codesigning` again reports zero valid identities.
Face calibration, native image/conflict/cancellation and companion interchange,
macOS 14/supported-release/VoiceOver evidence, controlled production workloads,
and signed final-candidate acceptance remain open. No release gate is closed.
