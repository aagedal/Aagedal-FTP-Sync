# Offline geocoding integration

Implemented at `ae62bd1` on `codex/version-3-0-plan`, following `401abd0`.
No candidate or manual acceptance is implied.

## Connected behavior

Independent job settings now request place-variable resolution and City/Country
writes separately. Existing jobs remain off. Each place field has disabled,
fill-empty and overwrite policies. A concrete output locale, fixed offline provider,
pinned dataset identity and 50 km nearest-settlement policy are validated in the
settings schema. The settings are outside metadata schedules and shared calendars.
Configuration packages with selected job settings require version 3, including
explicit all-disabled settings; legacy stores/packages refuse the new semantics.
Imported jobs remain stopped. Explicit saves/imports initialize a missing processing
zone, and runtime/preview require that saved context when geocoding is enabled.

The application shares an inert offline service across engines and previews rather
than constructing a queue/cache per picture. Only writable place fields and enabled,
writable location-variable dependencies request a lookup. One frozen coordinate
selection drives the lookup and scheduled GPS proposal. Missing coordinates, absent
results, deadlines and invalid field values preserve affected metadata and make the
operation incomplete; other valid fields can still apply. Accepted lookup names are
data, not template syntax. Existing City/Country preservation does not alter the
meaning of location variables. New place policies never enter shared scheduled-field
enums or calendar documents.

Regular and completed-directory early delivery include independent processing in
sidecar reservations and transformed-output comparisons. Geocoding runs without a
matching photographer/clip, or with no enabled schedule. RAW and XMP stay in the
existing transactional publication group. Standalone successful enrichment can move
a source pair to a managed/custom processed folder without inventing a photographer
folder. Incomplete enrichment retains the source. Successful base publications record
source receipts even for unavailable/no-op enrichment, preventing repeated processing
of the same delivered source. Failed processed publication/removal withholds both
main and sidecar receipts so an unchanged RAW with a changed sidecar can retry.

Local reprocessing uses optional assignments, frozen originals and byte-matched
publication for standalone enrichment. RAW output ownership is checked before writes,
including two RAW files sharing a sidecar stem. Pure standalone reprocessing does not
need source sessions or source credentials. Existing schedule-specific requirements
still apply when an enabled schedule requests source-modification or original-arrival
context; these remain distinct from standalone operation.

## Controls, preview and evidence

The job editor's Offline geocoding section exposes Resolve place variables, Write
city, Write country and Place-name language. Reading the controls creates no settings.
English is an explicitly shown default; selecting a control creates a draft only.
Save the job before Preview Geocoding or Reprocess Saved Files. Reprocessing uses
saved settings and any enabled saved schedule; it confirms the destination scope.

The async preview is cancellable and read-only, supports absent/disabled/unmatched
schedules, and presents separate existing/proposed City/Country values, preservation
and unavailable outcomes, lookup source and distance. Audit records retain stage,
locale, provider/dataset identity, distance and field outcomes without place names or
numeric coordinates. Lookup completion and resolved proposals are not publication
success. Legacy audit entries retain absent optional keys.

## Review findings resolved

Independent review found and fixed a strict-sidecar bypass: policy reads could use
the permissive legacy XMP tokenizer and suppress all lookups before structural
validation. Enabled geocoding now validates RAW sidecars before any scheduled/place
policy reads, including variables-only and all-preserved fields. Direct resolved
place assessment/writing also validates captured XMP. Legacy nil-place writing is
unchanged. Focused malformed-but-tokenizable sidecar tests preserve original bytes.

Review also identified repeated incomplete enrichment with processed folders and a
changed-sidecar recovery trap. Receipts now suppress repeated successful base
publications while failed processed publication/removal withholds the whole source
pair's updated receipt. Shared-sidecar ownership preflight was added to reprocessing.

## Verification

The initial integrated run discovered 928 tests and reported three assertions across
two tests: legacy missing-zone wording changed unintentionally, and the new scope
fixture lacked local bookmarks. The second run isolated one remaining fixture issue:
the remote SFTP endpoint also needed a valid-shaped test fingerprint before reaching
geocoding scope validation. The production wording now preserves the legacy message
when geocoding is off; the fixtures satisfy existing endpoint checks. No admission,
trust, stale-clear or processing assertion was weakened.

Final result: **928 discovered, 913 passed, 15 opt-in skips, zero failures** at
2026-09-11 18:45:03 +0200, 50.608 seconds; xcodebuild exit 0. This adds 45 tests over
the previous 883-test baseline.

- Passing log: `build/m2-offline-integration/full-tests.log`; SHA-256
  `e52df0fcb33de49d26d3a277d793adbd5f0597050b7a050b59a3f168513d11fa`.
- Initial failure log: `build/m2-offline-integration/initial-test-failure.log`; SHA-256
  `e36ee51904b00ed01f2576523c2817e09e58486fedc991e5df19ad1593e5d3d4`.
- Second failure log: `build/m2-offline-integration/second-test-failure.log`; SHA-256
  `330750f5b455f4d6403bbb3d36804a50d3c4ed8252cd21e5ecbba79bbae96c70`.
- xcresult: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.11_18-44-08-+0200.xcresult`.

Commands (serialized; generated project included in source commit):

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Environment: arm64 macOS 27.0 (26A428), Xcode 26.6 (17F113). Development app remains
2.9.2 (37); installed stable copy unchanged. The tested working tree contained this
source slice before its local commit; no application source changed after the final
passing run. Fixtures use temporary local endpoints, fake providers, synthetic GPS
images/RAW dispatch, isolated stores and deterministic settings. They cover independent
lookup/writes, no-GPS/failure source retention, repeated polls, new/preserved sidecars,
processed-folder pair recovery, strict XML rejection, preview, migration and audit.

Independent agents reviewed settings/codec fences, preparation/writing, preview/UI and
the root transfer/reprocess/receipt integration. Final wording/fixture review found no
remaining actionable regression. The final remote test fingerprint only satisfies
structural validation and is never used for a network connection.

Checklist cases m2-001/002/003 now name the implemented controls, saved preview and
reprocess workflow. All 42 stable IDs remain; JSON validation passed. No human result
file exists, and no agent or user native case was marked passed. Unit tests and
synthetic RAW dispatch are not native UI, real-camera RAW, supported-OS or live
geographic validation.

## Remaining gates

- Actual native controls, preview/reprocess/processed-folder workflows and accessibility
  remain unobserved. The companion task's latest snapshot was still active in native
  rotation/Metadata Review testing; desktop use was deferred. Prior XCTest authentication
  cancellation was not bypassed. Human checklist results remain absent/unmodified.
- Apple online selection and explicit coordinate-sharing consent are not wired into
  production settings; the availability-gated adapters remain a separate foundation.
- Real offline rural/coastal/border validation, representative bursts, supported-OS
  execution and system Expat runtime compatibility are still required.
- M5 needs durable processing fingerprints and stale/incomplete filtering. Existing
  destinations without source receipts can still take the legacy bootstrap path when
  new processing/processed-folder settings are enabled. Do not claim full settings-change
  idempotence or candidate readiness from same-source repeat-poll tests.
- Protocol 3 sharing, model/library/face recognition and full release gates remain open.
