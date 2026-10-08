# Authorized pseudonym face evaluation — 2026-10-08

The user authorized a local event-photo folder and requested random names for
reference identities. Originals are read-only. Images, crops, vectors, names,
labels, capture metadata, manifests and package outputs remain beneath ignored
`build/face-evaluation/`; none is committed or uploaded.

## Scan and independent labels

The folder contains 803 files. The evaluation excludes 336 hidden cached
thumbnails and scans 225 actual capture images. These correspond to 171 capture
groups after grouping same-camera capture seconds and camera-style filename
variants. RAW/JPEG/DNG versions of the same capture cannot cross reference,
calibration and held-out roles.

The diagnostic scanner uses the bundled production runtime. Face boxes now come
from that same analysis pass, rather than a second Vision request whose ordinals
could differ. This observation field is diagnostic only and does not change
model input, matching, metadata or persisted audit records. Output paths resolve
inside the checkout's ignored build directory; original hashes are checked.

The initial authoritative scan completed 219 images and failed diagnostic crop
validation on six images with partly off-frame faces. The validator was corrected
to retain the original production box while clipping only the display crop.
A six-image rerun then passed. Combined: 225 images, 354 detected faces, nine
zero-face images, no remaining scanner failure. The earlier cached-thumbnail
scan and failed partial run are not counted as independent accuracy evidence.

Existing automatic clusters were only a candidate-label source. All 220 selected
actual production crops were visually checked; mixed clusters were corrected and
uncertain identities excluded without consulting matcher scores. Twenty identities
received private random pseudonyms and one reference each. Same-capture variants
of references were excluded. A frozen capture-group hash split then produced
32 calibration and 146 held-out queries. Labels and reviewed crop hashes are
pinned alongside scanner-record and source-image hashes.

## Fixed shipped policy, no held-out tuning

| Partition | Known | Correct names | Missed known | Unknown | False names |
| --- | ---: | ---: | ---: | ---: | ---: |
| Calibration | 28 | 24 | 4 | 4 | 0 |
| Held out | 124 | 120 | 4 | 22 | 0 |

Held-out known recall is 96.8%; all 22 selected unknown faces abstain. One known
face is quality-rejected, and three further known faces return no match. Policy
is the shipped distance 0.68, runner-up gap 0.04, quality 0.15, reject-unavailable
quality setting. No policy was changed using these results.

The three-test evaluation run passed, with logs in
`/private/tmp/aftpsync-v3-oct08-face-matching.log`. These are selected detected
faces from one event, not a detector recall measurement or general-population
accuracy guarantee. The private report explicitly records
`detectionAccuracyEvaluated: false` and `releaseGatePassed: false`.

## Real RAW decode defect discovered

Inspection of nine zero-face images found five Sony Lossless Compressed RAW2
ARWs and two JPEG XL DNGs rendered nearly black or strip-corrupted by the current
ImageIO forced-thumbnail path. Independent installed LibRaw half-size sensor
renders correctly show the five ARW scenes. LibRaw cannot decode the two DNGs,
so their sensor payload has no independent validation yet.

A read-only ImageIO probe shows usable, oriented embedded previews for all seven
files when thumbnail creation from the sensor image is disabled. This isolates
a material problem in the current decode path: successful image allocation can
silently become successful no-face analysis on unusable pixels. Darkness or zero
faces alone must not be treated as an unsupported-codec test.

Photo Agent's pinned face detector uses the same forced-thumbnail behavior; its
separate CIRAWFilter display loader does not establish compatible recognition
preprocessing. A production correction needs explicit decode-policy identity,
receipt invalidation, orientation/resolution tests and matching revalidation.
The current preprocessing contract states that semantic changes require a new
identity. No production decoder change, unsupported-codec waiver or final
recognition/RAW gate pass is claimed here.

Private diagnostics: `zero-detections.local.json`, `libraw-diagnostics/`,
`imageio-diagnostics/` and their contact sheets. Originals remain untouched.

## Harness provenance review

Independent review identified and resolved two export issues: an arbitrary older
commit could be labeled as producer source, and a crop replaced before export
was not bound to the reviewed bytes. Export now requires current HEAD and clean
relevant tracked/untracked source before and after generation, plus reviewed
crop SHA-256 verification. New scanner records also include crop hashes.
Focused checks pass eight tests with three explicitly unconfigured opt-in skips;
these skips are not package-export or scan passes. Log:
`/private/tmp/aftpsync-v3-oct08-face-harness-final.log`.

The Core Image RAW probe was repeated with native service access after a sandboxed
run could not render. With native service access, CIRAWFilter decoder 8 (8.dng for the DNGs)
renders all seven scenes correctly in quarter-size SDR sRGB. This is a promising
sensor-decode repair path; it is diagnostic evidence, not yet a production
preprocessing or matching-compatibility change.

## Generated private reference package

From clean source `a24d34f4e5022ebb9429082c3410f79cf6230745`, the
opt-in export test passes with zero skips: 20 people, 20 references, schema 3.
Production repository admission, package export and reimport preserve names,
counts and all 178 calibration/held-out query outcomes (including distances).
Reviewed crop, source and record hashes are rechecked. Log:
`/private/tmp/aftpsync-v3-oct08-reference-export.log`.

The private package is
`build/face-evaluation/reference-library-01/Pseudonym Reference Library.aagedalpeople`.
It is generated by the FTP test helper, not exported by native Photo Agent.
Native companion exchange, final signed Release observation, decoder correction
and the remaining release gates stay open. No real names were inferred.

Next decoder work: compare healthy RAW/JPEG/HEIC controls with a bounded, oriented
SDR sRGB CIRAWFilter implementation; define the shared preprocessing/decode
revision and prior-receipt invalidation; prepare the companion change without
modifying its active checkout; regenerate/re-enroll references and rerun capture-
disjoint matching. Do not preserve a stale processing identity merely to admit
an old library, and do not label this diagnostic probe as the production repair.

## Integrated regression

At source `a24d34f`, the complete non-UI suite passes 1,282 executed tests,
30 explicitly opt-in skips and zero failures in 35 seconds. The private package
export passed separately without skips. Log:
`/private/tmp/aftpsync-v3-oct08-face-integrated.log`. Build 43 remains the earlier
registered archive from `6501476`; no new candidate binary is implied by this
harness-source verification.
