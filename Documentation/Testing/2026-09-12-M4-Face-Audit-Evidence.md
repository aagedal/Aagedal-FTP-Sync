# M4 redacted face-recognition audit evidence

Date: 2026-09-12  
App-code commit: `33c3a0268fca673c8d7415ff15c0a406416f1f16`  
Machine: MacBook Pro (Mac17,8), Apple M5 Pro, 64 GB  
Operating system: macOS 27.0 (26A428)

## Scope

FTP Sync now has an additive, backward-compatible durable audit projection for a
future admitted face-recognition runtime. `MetadataAuditEntry` can carry typed
recognition evidence while existing stored entries decode unchanged and new entries
without evidence continue to omit the field.

The projection records only:

- a typed result or failure state;
- aggregate face outcome counts;
- fixed recognition-contract provenance, including library schema, component,
  model, preprocessing, vector format, dimension, a validated lowercase SHA-256
  runtime revision and a deterministic SHA-256 acceptance-policy revision; and
- aggregate resource-bound context when a bounded operation is rejected.

It deliberately does not retain face names, person or library identifiers,
embeddings, candidate scores, face geometry, file paths, provider text, or
per-face ordinals. The audit trail has a collapsed **Recognition details** section
that presents the typed status, aggregate counts and immutable provenance when
evidence exists.

This is infrastructure evidence, not recognition acceptance evidence. No model is
loaded, no production recognition flow attaches the projection yet, and no real-face
or calibration result is claimed. Normal metadata audit entries also remain outside
the support bundle; the existing support-bundle privacy tests continue to enforce
that boundary.

## Exact verification

The following focused selection ran on the exact clean app-code commit:

```sh
xcodebuild test -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-face-audit \
  -only-testing:AagedalFTPSyncTests/MetadataProcessingAuditEvidenceTests \
  -only-testing:AagedalFTPSyncTests/MetadataAuditTests \
  -only-testing:AagedalFTPSyncTests/SupportBundleTests \
  -only-testing:AagedalFTPSyncTests/FaceRecognitionAnalysisServiceTests \
  CODE_SIGNING_ALLOWED=NO
```

Result: 47 tests passed, zero failures and zero unexpected failures.

Result bundle:
`build/DerivedData-face-audit/Logs/Test/Test-AagedalFTPSync-2026.09.12_20-33-02-+0200.xcresult`

The exact clean app-code commit also passed an unsigned Release build:

```sh
xcodebuild -scheme AagedalFTPSync -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-face-audit-release build \
  CODE_SIGNING_ALLOWED=NO
```

Result: `** BUILD SUCCEEDED **`.

## Covered behavior

The focused tests verify legacy omission and decode compatibility, private-data
redaction, exhaustive aggregate outcome counts, codable round trips, typed resource
failure mapping and presentation, and strict runtime-revision validation. Existing
face-analysis, metadata-audit and support-bundle tests were included to cover the
adjacent boundaries.

## Remaining acceptance work

- Admit an identity-bound production runtime only after the pinned BGR/RGB contract
  discrepancy and companion schema-2 artifact requirements are resolved.
- Attach the projection to preview, transfer and reprocessing paths without exposing
  private recognition details.
- Run supported-OS, native UI/VoiceOver, real-model, real-face and calibrated accuracy
  verification.
- Measure and tune the provisional resource caps with representative workloads.

