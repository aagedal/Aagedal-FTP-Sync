# M4 admitted AuraFace runtime foundation

Date: 2026-09-12
App-code commit: `22ebc7e83b757f273e82eb31de28603fef6aefbc`
Machine: MacBook Pro (Mac17,8), Apple M5 Pro, 64 GB
Operating system: macOS 27.0 (26A428)

## Scope

FTP Sync now has a Release-capable, fail-closed inference runtime that can be
constructed only from the signed component installer's revalidated current
component. Admission holds the component lock while it verifies the descriptor
and package again, validates the exact Core ML interface, derives a lowercase
SHA-256 runtime revision from the canonical signed descriptor, and loads the
`MLModel`. The returned runtime retains that model in memory, so a later update or
removal cannot retarget an already admitted operation.

The extracted image path is pinned to Aagedal Photo Agent revision `78f0209` and
contains only the bounded recognition work needed by FTP Sync:

- orientation-aware ImageIO decode capped at 4,096 pixels;
- Vision landmark detection, confidence 0.7 and a 50-original-pixel face-width
  minimum;
- capture-quality collection, deterministic face ordering and a typed face-count
  cap;
- the companion's two-eye ArcFace 112-pixel alignment with a bounded crop
  fallback;
- exact RGB float32 NCHW input normalization `(x - 127.5) / 127.5`;
- strict `input` and `embedding` interface validation and exactly 512 finite,
  nonzero output values; and
- L2 normalization through FTP Sync's existing validated embedding type.

`FaceRecognitionAnalysisService` can now wrap an admitted runtime and its existing
bounded serial worker/matcher. The default service remains unavailable. Production
startup and job paths do not construct the ready service yet because a dedicated
distribution trust key/fixed hosts and calibrated acceptance policy are not
available.

## Companion contract evidence

The adjacent Photo Agent now has a canonical schema-2/ZIP32 producer at `1147d8e`
and committed RGB reference evidence at `78f0209`. The optional local model file
used for this verification had SHA-256:

```text
b60588562fd76717d0d6ddcfcb8a4bf2d2bda3d61b356721b379318adf366f85
```

The pinned artifact declares float32 `[1, 3, 112, 112]` input and float16
`[1, 512]` output. FTP Sync admits that actual interface (and the equivalent
float32 output) while still requiring the exact model, component, preprocessing
and embedding-space identity from its people-library contract.

The opt-in production-path test decoded the companion's hash-bound asymmetric PPM
fixture, verified the model and fixture hashes, compiled the package, then invoked
FTP Sync's real input packer and Core ML prediction path. The RGB embedding met the
companion threshold of cosine similarity at least 0.999. Deliberately swapping red
and blue stayed at or below the 0.8 negative threshold. This resolves the earlier
BGR/RGB discrepancy for this pinned artifact; it is not a face-accuracy calibration.

## Exact verification

The broader affected selection ran against the committed source. The three
`AAGEDAL_AURAFACE_*` paths were supplied to the app-hosted test as temporary local
launch environment variables and removed from the shared scheme afterward.

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-face-runtime-build \
  -only-testing:AagedalFTPSyncTests/AuraFaceRecognitionRuntimeTests \
  -only-testing:AagedalFTPSyncTests/AuraFaceComponentInstallerTests \
  -only-testing:AagedalFTPSyncTests/FaceRecognitionAnalysisServiceTests \
  -only-testing:AagedalFTPSyncTests/FaceRecognitionMatcherTests \
  -only-testing:AagedalFTPSyncTests/PeopleLibraryManifestTests \
  -only-testing:AagedalFTPSyncTests/PeopleLibraryRepositoryTests \
  -only-testing:AagedalFTPSyncTests/MetadataProcessingAuditEvidenceTests \
  CODE_SIGNING_ALLOWED=NO
```

Result: 70 tests passed, zero skips, zero failures and zero unexpected failures.

Result bundle:
`build/DerivedData-face-runtime-build/Logs/Test/Test-AagedalFTPSync-2026.09.12_22-02-28-+0200.xcresult`

The same source passed an unsigned Release build:

```sh
xcodebuild build -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-face-runtime-release \
  CODE_SIGNING_ALLOWED=NO
```

Result: `** BUILD SUCCEEDED **`.

Release app:
`build/DerivedData-face-runtime-release/Build/Products/Release/AagedalFTPSync.app`

Warnings were the existing vendor concurrency/deprecation diagnostics and the
existing no-AppIntents-dependency metadata warning; no new app error occurred.

## Remaining acceptance work

- Select a dedicated model-distribution public key and fixed HTTPS hosts, then
  regenerate and sign production artifacts.
- Define an identity-bound startup admission token and connect one immutable
  runtime/library/policy snapshot to preview, transfer and reprocessing.
- Calibrate distance, runner-up-gap and quality thresholds on authorized labeled
  real-face fixtures; tune the provisional resource caps with measured workloads.
- Attach the existing redacted audit projection and integrated outcome UI.
- Run supported-OS, native UI/VoiceOver, real-image, lifecycle, performance and
  final manual acceptance checks.
