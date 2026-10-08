# M1 saved zones and existing-value inspection — 2026-09-11

Implementation commit: `cab50f3`, following baseline `5c4cc2f`. This checkpoint makes the saved processing zone, existing
metadata and recorded processing assumptions inspectable without changing legacy
writer behavior or enabling geocoding/recognition.

## Changes

Job metadata settings expose a searchable Processing time zone chooser, explicit
Use This Mac’s Zone, and literal-only Clear Choice. Opening/searching does not
initialize a missing zone. Selection changes the draft; saving changes future
processing, not existing files or schedule timestamp policy. Stale settings drafts
preserve a zone saved from another window unless the user explicitly replaces it.
Invalid choices fail without changing the previous value. Clearing an older literal
draft after variables were activated elsewhere is rejected instead of resetting the
newly saved zone to the Mac setting.

Real-file preview now shows existing values beside proposals and field outcomes.
Embedded IPTC, XMP and EXIF carriers remain separately labeled when they disagree.
RAW uses its existing sidecar, or the same embedded metadata seeding used by writer
policy when no sidecar exists. Unknown/unreadable metadata is explicitly unavailable,
not presented as an empty field. Snapshots remain in memory and never enter audit
storage. Source images and sidecars are not modified by these reads.

Preview identifies explicit capture offsets and saved fallback-zone assumptions.
Audit rows expose Processing details with the recorded processing time/zone, capture
assumption and field-level outcomes. Resolved proposals are explicitly distinct from
successful publication. An unavailable recorded zone uses visibly labeled UTC for
display instead of silently using the current Mac zone. No resolved private text is
added to the audit evidence object.

## Review and validation

Independent review covered preview carrier precedence, unchanged RAW writer behavior,
per-file read failures, audit publication wording and zone display. Native layout,
VoiceOver and supported-OS evidence remain separate requirements. Full suite: **861 discovered, 846 passed, 15 opt-in skips, zero failures**, exit 0
at 2026-09-11 17:17:51 Europe/Oslo, 33.286 seconds. Fifteen new tests cover seven
zone-editing cases, five existing-value cases and three audit-presentation cases.
No source changes followed the passing run.

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Environment: Xcode 26.6 (17F113), arm64 macOS 27.0 (26A428), development app 2.9.2 (37).
Tested dirty state contained this source/project/test slice and its documentation.
Installed stable copy and human results were not changed.

- Log: `build/m1-context-inspection/full-tests.log`
- SHA-256: `6a4c808cc990736712bc2189afb8428f461f7783220c1567b20b05b5cb157bb7`
- xcresult: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.11_17-17-14-+0200.xcresult`

The first integrated run found one fixture expectation mismatch: the pinned metadata
reader normalizes surrounding XML subject whitespace. The fixture now uses the
reader-supported `ordered` value while retaining separate IPTC/XMP, comma-bearing
keyword, entry-order and unchanged-file assertions. Product code did not change to
satisfy the fixture. The original failure log is retained under
`build/m1-context-inspection/initial-test-failure.log`.

The companion task was actively performing native rotation checks in its latest
compact snapshot. Desktop interaction was deferred to preserve that session. The
previous separate XCTest runner authentication cancellation is not bypassed or
repeated. No native app pass or human checklist result is claimed here.

## Next integration boundary

An independent read-only investigation confirmed the known RAW GPS mismatch: with
valid EXIF coordinates, an existing sidecar without coordinates, and scheduled
fill-empty coordinates, the effective-coordinate resolver preserves EXIF while the
legacy sidecar writer permits the scheduled pair. Preserve legacy behavior; the new
geocoding path must freeze effective coordinates once and suppress the scheduled GPS
proposal when that result preserves the existing pair. Validate absent, empty,
conflicting and malformed sidecars, fill/overwrite and RAW byte preservation before
connecting geocoded values.

Standalone geocoding requires optional-assignment processing, independent job settings,
shared provider instances, and City/Country writer policies. Merely exposing provider
settings in the current assignment-only pipeline would not implement no-clip operation.
The next slice should connect offline lookup end to end, retaining explicitly gated
Apple selection and avoiding provider creation per image/run.
