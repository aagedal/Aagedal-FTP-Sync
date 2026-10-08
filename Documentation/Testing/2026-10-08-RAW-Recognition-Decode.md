# RAW query decoding correction — 2026-10-08

The user confirmed the seven flagged originals display correctly and requested a
recognition-decoder repair. The defect was the forced ImageIO thumbnail used for
face queries, not damaged originals. The old path yielded nearly black or
strip-corrupted pixels for five Sony compressed ARWs and two JPEG XL DNGs.

## Implementation

A shared `FaceRecognitionImageDecoder` selects RAW using the decoded content UTI,
not the filename extension. RAW uses `CIRAWFilter` sensor decoding, its native
size and EXIF orientation, zero exposure, zero extended dynamic range, no draft
mode or user filters, and explicit 8-bit SDR sRGB output capped at 4,096 pixels.
Finite geometry is checked before rendering. If RAW decoding fails, analysis
returns an image-read failure; it does not fall back to the broken forced
thumbnail and report a successful no-face result. JPEG/HEIC retain the original
ImageIO path. Source bytes are never edited.

The versioned query identity is
`photo-agent-eyes112-rgb-v3+apple-ciraw-sdr-srgb4096-v1`.
The model/alignment/RGB tensor, saved reference preprocessing identity, matching
policy and immutable libraries remain unchanged. Production explicitly declares
support for the strict existing v3 reference contract. This is query-side
compatibility, not a claim that old reference vectors were regenerated.

Runtime processing identity now hashes the admitted model identity, query policy
and OS version/build (Apple decoder selection is OS-dependent). It reaches the
existing `face-runtime` receipt dependency, invalidating old outcomes when the
new runtime is admitted. Audit records distinguish reference preprocessing from
query preprocessing; older records without the optional query field remain
readable as legacy ImageIO. No automatic library relabeling is performed.

The private evaluation harness requires current query identity for a current
pipeline run while permitting frozen v3 references. It refuses newly corrected
RAW records as compatibility references or v3 package exports. Scanner crops use
the same decoder as the runtime, eliminating a second decode-policy copy.

## Verification

The decoder type-checks for `arm64-apple-macos14.0`. This proves API availability,
not macOS 14 runtime behavior. Focused application checks pass 45 tests with three
unconfigured opt-in skips and zero failures. All seven affected originals pass
the production scanner with original hashes preserved. Their retained working
images were visually inspected: all seven render correctly, including rotated
portraits. One face is now detected in a previously black portrait; remaining
zero-face results are detection outcomes, not evidence of failed decoding.

Regression tests cover JPEG pixels and all eight orientations, legacy JPEG
4,096-pixel downsampling, content-based routing despite a misleading extension,
invalid RAW/geometry rejection, model/query/host identity invalidation, legacy
and current audit round trips, and legacy/current matching-manifest routing.
The first compilation found ambiguous CGFloat infinity in a test fixture; it was
made explicit before the successful run.

Log: `/private/tmp/aftpsync-v3-oct08-raw-decode-focused.log`.
Private evidence remains under ignored `build/face-evaluation/`, including
`scan-ciraw-regression-01/` and `ciraw-fixed-contact.local.png`.

Independent read-only reviews found no blocking decoder or production identity
issue. The matching loader was tightened after review to prevent corrected RAW
references from masquerading as unchanged v3 compatibility evidence.

The full-event rescan passes 225 images, 353 detected faces, zero failures,
original hashes unchanged (217 seconds). All 178 frozen query labels map to the
corrected detections and were visually checked again before matching. No query
was excluded. The gallery remains the same 20 frozen v3 references; all 178
queries are RAW. Calibration remains 24/28 known correct, 4/4 unknown abstentions;
held out remains 120/124 known correct, 22/22 unknown abstentions, zero false names.
All discrete decisions remain unchanged; the nearest candidate changes for nine
abstentions, without publishing a name. No thresholds were tuned. The 19 non-RAW
capture images retain identical detected-face counts and embedding float values.
This is same-event selected-face evidence, not overall detector accuracy.

Logs: `/private/tmp/aftpsync-v3-oct08-raw-decode-event-scan.log` and
`/private/tmp/aftpsync-v3-oct08-raw-decode-matching.log`.
The integrated non-UI suite passes 1,290 executed tests, 30 opt-in skips, zero
failures. The final archive advances to build 44; build 43 is retained intact.
Log: `/private/tmp/aftpsync-v3-oct08-raw-decode-integrated.log`.

Peak decoder memory, cold/warm budgets, sensor-RAW orientation coverage beyond
these samples, cancellation latency, macOS 14 and final signed-native acceptance
remain open. The output cap is not a guarantee of peak decoder allocation;
synchronous Core Image rendering cannot be interrupted midway. No ready-for-
release or whole-detector accuracy claim is implied by these scoped checks.
