# M4 face-recognition orchestration foundation

Date: 2026-09-12
App-code commit: `4f26d6e`
Release status: implementation evidence only; production recognition remains disabled.

## Implemented

- A strict schema-1 job setting records the optional choice to publish accepted
  names to keywords. Missing settings remain off. Presence requires v3 storage
  and configuration transfer, while model, people-library and acceptance-policy
  identities remain runtime dependencies rather than portable job data.
- Settings decode rejects null, missing, unknown, malformed and future fields.
  Typed errors prevent backup recovery from silently discarding a requested
  recognition stage. One-way jobs with a local destination are required.
- Normal sync, local reprocessing and metadata preview now fail closed before
  endpoint or bookmark access when recognition is saved but its production
  runtime has not been admitted. The message explains how to disable the stage
  and continue without recognition.
- `FaceRecognitionAnalysisService` defines bounded, cancellable orchestration
  around an injected analyzer and matcher. It validates the face count, canonical
  ordinals and capture quality before publishing any identity result; provider
  errors are projected to typed values without retaining paths or provider text.
- Accepted identities are deduplicated by stable person ID and then normalized
  name. Literal commas and braces are preserved. Matching checks cancellation at
  gallery boundaries and every 64 embedding components.
- Release builds expose only unavailable service construction while the
  preprocessing contract remains unverified. Ready injection is compiled only
  for tests until a production admission token binds the component, model,
  preprocessing, people library and calibrated policy identities.

## Review and verification

Independent review identified silent omission in normal sync, reprocessing and
preview; a production construction bypass; and a missing final cancellation
boundary. The implementation was updated to fail closed at each entry point,
hide ready construction from Release builds and recheck cancellation before
completion.

- Focused orchestration result:
  `build/DerivedData-face-orchestration/Logs/Test/Test-AagedalFTPSync-2026.09.12_17-00-39-+0200.xcresult`
- 31 passed, zero failed, zero skipped: matcher, analysis service, persisted
  settings/transfer/runtime boundaries and the focused preview guard.
- Broader affected persistence/transfer result:
  `build/DerivedData-face-orchestration/Logs/Test/Test-AagedalFTPSync-2026.09.12_16-48-59-+0200.xcresult`
- 67 passed, zero failed, zero skipped.
- A macOS Release build passed with code signing disabled using
  `build/DerivedData-face-orchestration-release`.
- `git diff --check` passed before commit.

One broad `MetadataProgrammingCoordinatorTests` invocation was stopped after
the Xcode 27 test host stalled while materializing/finalizing workers. The exact
new preview test subsequently passed in the 31-test result above, so the stalled
run is not counted as regression evidence.

## Deliberate blockers

- No production admission token or model-backed detector/alignment/embedding
  operation exists. The BGR/RGB preprocessing discrepancy must be resolved with
  committed reference-vector evidence first.
- Commit `4f26d6e` did not yet include queue, pending-byte, deadline or gallery
  caps. Later implementation evidence records provisional safety caps; measured
  benchmark-derived budgets and tuning remain open.
- Durable redacted recognition audit projection is not yet implemented.
- Photo Agent still needs a canonical schema-2 ZIP32 exporter and signed artifacts.
  Neither app has the shared App Group entitlement needed for automatic local sync.
- Calibration, supported-OS, real-model, authorized real-face and native settings
  workflows remain open acceptance work.
