# M5 saved reprocessing preflight — 2026-09-19

Development source: clean base `792b0bf` plus the code, test and documentation
changes committed with this report. Host: arm64 macOS 27.0 (`26A428`), Xcode 27.0
(`27A266a`). Version remains 2.9.2 (37). Candidate identity is unchanged; no local
human acceptance results JSON was present.

## Changes

The shared Saved metadata processing section now offers stale/incomplete or all
matching files and starts the existing no-write engine preflight before exposing
write actions. Its dialog reports ready/skipped/failed counts and edited-output
conflicts. Ordinary confirmation preserves edits; the separate destructive action
passes only the reviewed path/content revisions to the existing conflict policy.
Edits made after that review remain protected by the engine.

The review captures the entire saved job and filter. Changed saved settings,
unsaved draft edits, a changed filter, external-writer suspension and leaving the
editor discard the pending review and cancel an active preflight. Confirmation
rechecks current saved settings, busy state and runtime admission. Running,
completed and failed outcomes are visible in the section. AppStore now notifies
busy-state consumers when the final reprocessing/preflight task releases its
lease and clears, so confirmation controls can refresh after a ready result.

## Verification

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/MetadataProgrammingCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

Final exit 0: 64 tests passed, no failures or skips. The new review regression
rejects changed settings, filters, scopes and unfinished phases. Existing activated
integration cases cover no-write preflight, face-only processing, filtered idle
repeats, explicit edit approval, newly edited files and a reviewed file changed
again before reprocessing.

Log: `build/v3-saved-preflight-final.log`. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_18-37-01-+0200.xcresult`.
The initial sandbox attempt could not write compiler/SwiftPM caches; an approved
retry passed. An intermediate implementation using a published task dictionary
failed compilation due to nonisolated deinitialization; explicit main-actor
notifications replaced it before the successful final run.

Security baseline, current release identity, string-catalog JSON validation and
`git diff --check` pass. No release-version bump or candidate readiness claim.

## Remaining verification

Photo Agent and Media Player tasks were active on the shared desktop. Native
observation of the filter, live dialog updates, cancellation, dismissal and
keyboard/VoiceOver behavior remains open. The focused engine tests do not replace
that evidence, camera RAW, real-face calibration, supported-OS coverage or final
signed-candidate acceptance. No milestone/checklist gate was marked complete.
