# M5 programming review invalidation — 2026-09-19

Development source: clean base `22a6549` plus the code, tests and documentation
committed with this report. Host: arm64 macOS 27.0 (`26A428`), Xcode 27.0
(`27A266a`). Version remains 2.9.2 (37). No local human acceptance results JSON
was present. The older development candidate identity is unchanged.

## Changes

Metadata Programming previously accepted a completed preflight based only on its
scope and filter. A saved policy or draft change could therefore leave approval
available for an operation whose settings had not been reviewed.

The programming coordinator now captures the complete saved job and binds ready
results to that snapshot, its draft, selected job, scope and filter. It rechecks
these conditions synchronously at confirmation, before SwiftUI change callbacks
need to run. Changed settings, draft, filter, selection or external-writer
suspension dismiss pending review. Leaving the view or switching jobs cancels an
in-flight preflight. Admission and confirmation also recheck runtime availability
and job busy state; confirmation controls reflect those restrictions.

The existing saved-job review helper now supports photographer/clip scopes as
well as all files. Saved-job actions retain their existing all-file behavior.

## Verification

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/MetadataProgrammingCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
```

Final exit 0: 66 tests passed, zero failures or skips. New tests run real
no-write preflight against disposable, bookmarked empty local folders, then
attempt confirmation after draft, filter, saved overwrite-policy or selection
changes and cancellation. Each rejects approval without enqueuing writes. A
separate test cancels preflight before completion. Scope matching also covers a
clip review and rejection of an unrelated all-file result.

Log: `build/v3-programming-review.log`. Result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_18-43-56-+0200.xcresult`.
The sandboxed attempt could not access compiler/SwiftPM caches; an approved retry
ran the suite. Intermediate test fixtures were corrected for a computed property
and for geocoding activation being unavailable in the legacy fixture store.

Security baseline, current release identity and `git diff --check` pass.

## Remaining gates

Native dialog refresh, dismissal, keyboard and VoiceOver behavior still require
observation; other project tasks were active on the shared desktop, so this run
used isolated non-UI checks. These tests do not establish camera-RAW, real-face
calibration, supported-OS or signed-candidate acceptance. No milestone or checklist
case was marked complete, and no release identity was changed.
