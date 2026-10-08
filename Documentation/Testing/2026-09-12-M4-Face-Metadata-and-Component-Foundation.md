# M4 face metadata and optional component foundation

Date: 2026-09-12
App-code commit: `f6f8407`
Release status: implementation evidence only; recognition remains disabled.

## Implemented

- `ResolvedMetadataChanges` can carry literal accepted person names without
  interpreting commas or template braces.
- Embedded files and RAW XMP sidecars append names to
  `Iptc4xmpExt:PersonInImage`. An explicit caller choice can also append each
  intact name to IPTC/XMP Keywords. Existing values are retained with stable,
  fixed-locale deduplication.
- Assessment and writing share the same combined scheduled-keyword/face-name
  result. Repeated writes are idempotent, unreadable or linked sidecars fail
  closed, and a generated sidecar cannot exceed the reader's 8 MiB admission
  limit.
- An isolated AuraFace component foundation now defines an injected Ed25519
  trust contract, canonical schema-2 descriptors, capped no-redirect downloads,
  a strict exact-three-file ZIP32 reader, verified extraction, Core ML
  compilation, cancellable installation, offline inspection/removal,
  current/rollback recovery, private storage and cross-process serialization.
- Component status deliberately reports `installed`, and exposes no compiled
  model URL. No runtime can consume the component from this slice.

## Review and verification

Independent review found and the implementation fixed missing target membership,
locale-dependent name deduplication, oversized generated sidecars, a Swift 6
sendable-capture error, mutable model URL exposure, interrupted rollback handling,
unsafe parent creation, concurrent stage cleanup, and a misleading runtime-ready
state.

Focused result:

- Result bundle: `build/DerivedData-people-settings/Logs/Test/Test-AagedalFTPSync-2026.09.12_15-42-37-+0200.xcresult`
- 14 passed, zero failed, zero skipped.
- Adversarial installer result bundle: `build/DerivedData-face-installer-adversarial/Logs/Test/Test-AagedalFTPSync-2026.09.12_16-14-38-+0200.xcresult`
- 11 passed, zero failed, zero skipped. This adds explicit rejection coverage for
  ZIP64 sentinels/extras, duplicate and case-colliding entries, special-file
  attributes, local/central metadata disagreement, and cancellation after
  extraction but before publication.

A full run discovered 1,069 tests and recorded 898 passes, 156 failures and 15
opt-in skips. The broad failure cluster is environmental: existing suites were
denied writes to `/private/tmp` with Cocoa error 513 / POSIX `EPERM` under the
current macOS 27/Xcode 27 test host. Two existing FTP timeout cases also failed.
This run is not release evidence. The earlier clean full-suite result at
`da3579e` remains the last broad regression baseline.

## Deliberate blockers

- The pinned model metadata says BGR/Torch 2.12 while the tracked manifest and
  Swift preprocessor say RGB/Torch 2.8. Recognition publication remains blocked.
- No dedicated production model-distribution public key or fixed production
  descriptor/signature URLs are embedded.
- Photo Agent now has a schema-2 directory contract and reader, but its production
  exporter still writes the legacy schema-1 package and its model packager forces
  ZIP64 local headers. The hardened FTP Sync contract requires a schema-2 export
  plus a deterministic ZIP32 STORED model archive. Both producers and their
  artifacts must be regenerated and re-signed.
- The Core ML artifact is excluded from Photo Agent's Git history. RGB is declared
  by code and manifests, but no committed labeled fixture compares the source
  ONNX output with Core ML for both channel orders. This proof must be non-skipping
  before the production analyzer can become reachable.
- Future recognition integration must load and validate a Core ML model from the
  signed package without reintroducing a mutable filesystem URL, then prove the
  preprocessing contract with pinned vectors and labeled faces.
