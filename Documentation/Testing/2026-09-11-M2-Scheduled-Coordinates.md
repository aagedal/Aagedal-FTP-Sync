# Activated scheduled-coordinate preparation

Implemented at `ef154f3` on 2026-09-11, from `c3a9bd6`, on
`codex/version-3-0-plan`.
This is a prerequisite correction for connected geocoding, not completion of M2.

## Behavior and compatibility

Activated per-image processing now reads and freezes a complete effective GPS pair
before proposing scheduled GPS. Preview, transfer and guarded local reprocessing
already share this preparation path. A valid existing pair is preserved under
fill-empty, including EXIF in a RAW image whose existing sidecar has no GPS.
Scheduled overwrite still replaces it. Literal schedules keep their previous fast
path and writer behavior; no coordinate I/O is added to literal preparation or to
activated preparation without scheduled GPS.

The reader preserves whole-source pairs, applies RAW XMP-first and embedded
EXIF-first precedence, and retains conflict and invalid-source decisions. It never
creates a sidecar. Corrupt or symbolic-link sidecars fail preparation rather than
silently substituting embedded metadata. If RAW embedded metadata cannot be read,
only a valid existing sidecar pair permits resolution. Absence of a reported conflict
in that case does not establish agreement with the unreadable embedded carrier.

The pinned EXIF reader interprets some malformed GPS rationals as zero. Activated
coordinate reading validates rational shape, denominators, direction references and
altitude instead. The pinned writer can round seconds to exactly 60 (for example
59.9 degrees becomes 59 degrees, 53 minutes, 60 seconds); the reader normalizes
that endpoint while rejecting seconds above 60 and retaining final coordinate bounds.
A valid scheduled fill into invalid/absent coordinates promotes
only the final GPS write policy to overwrite, so the legacy writer cannot silently
reject that approved fill based on a fabricated zero. Other field policies and stored
job settings remain unchanged. Invalid scheduled GPS is an explicit omission and
makes resolution incomplete, preserving the existing processed-source removal guard.

Preview shows valid GPS carriers separately. Audit details retain source names,
conflict presence, invalid-source names and scheduled disposition without numeric
coordinate pairs. Wording distinguishes proposals from successful publication. Old
audit evidence without coordinate decisions retains its prior encoded shape.

## Sidecar validation dependency

The pinned XMP tokenizer accepts plain text and some broken markup as an empty
XMP object. The new path therefore validates bounded captured bytes with the
macOS-provided Expat library before passing those same bytes to the pinned parser.
The small `Vendor/CExpat` module exposes the SDK header and links the system library;
no parser source or binary is vendored. This avoids an extra process per image and
avoids the in-process libxml2/ImageIO interference documented by the pinned library.
The supported sidecar format is well-formed UTF-8 XMP with an RDF root or Adobe
XMP wrapper. Non-XML/NUL padding formerly tolerated by the pinned tokenizer is
conservatively refused, leaving the original file available for recovery. The
preflight is limited to 8 MiB, depth 64 and 100,000 elements; DTDs are rejected.
Supported-OS runtime evidence for this new system API remains required.

## Verification

The first integrated run compiled and executed 880 tests, with 15 opt-in skips and
12 failed assertions across five tests (exit 65). These exposed two product defects:
permissive corrupt-XMP acceptance and overly strict rejection of the pinned writer's
exact-60-second rollover. The original 59.9-degree fixtures were retained; the reader
was corrected instead. Initial log: `build/m2-scheduled-coordinates/initial-test-failure.log`.


The corrected full suite passed: **883 discovered, 868 passed, 15 opt-in skips,
zero failures**, exit 0 at 2026-09-11 18:07:01 Europe/Oslo, 37.576 seconds.
Twenty-two new tests comprise twelve reader/structural-validation cases, seven
preparation-to-writer cases and three audit evidence groups. No source changes
followed the passing run. Independent review approved the final implementation,
including the two failure fixes, namespace/root rules, bounded reads, resource
cleanup, source-retention behavior and private audit format.

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Environment: Xcode 26.6 (17F113), arm64 macOS 27.0 (26A428), development 2.9.2 (37).
The tested dirty state contained the committed code/project/test slice and its
documentation. The installed stable copy and human results were unchanged.

- Log: `build/m2-scheduled-coordinates/full-tests.log`
- SHA-256: `fd727ce87ac9641091f2327e08f2a2b7f3cedbec0ca67c2ee5302af31249557b`
- Initial failure log SHA-256: `69f31dab4bd7e19194e080d4ddc009f960b3b520150fc35771ee6ee1f65fb961`
- xcresult: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.11_18-06-09-+0200.xcresult`
- Built app: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Build/Products/Debug/AagedalFTPSync.app`
- `otool -L` on its `Contents/MacOS/AagedalFTPSync.debug.dylib` confirms
  `/usr/lib/libexpat.1.dylib` (compatibility 7.0.0, current 8.0.0).

Synthetic JPEG fixtures dispatched through RAW paths verify policy and unchanged
bytes, not a real-camera RAW decoder or external-reader interoperability. Required
native, real RAW, geocoder and supported-OS gates remain open.

## Desktop and remaining integration

The Photo Agent companion task's compact snapshot remained active in native rotation
and Metadata Review testing. Desktop use was deferred; the previous XCTest runner
authentication cancellation was not bypassed or retried without changed conditions.
No native UI pass or human checklist result was recorded.

Next: optional-assignment processing with independent per-job geocoding policies,
shared service ownership, City/Country writer policies and an end-to-end offline path.
Reuse the frozen coordinate decision for lookup and final GPS writes. The current
slice neither exposes standalone settings nor enables location variables. No-clip
operation, real offline geographic validation and online adapter evidence remain gates.
