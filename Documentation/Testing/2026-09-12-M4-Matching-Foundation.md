# M4 matching and embedding codec foundation

This is an isolated numerical foundation, not enabled recognition or a release
candidate. No face data, private library or model is read by these components.

## Implemented behavior

- Immutable embeddings require exactly 512 finite values and a nonzero norm.
  Imported normalized vectors must have an L2 norm within 0.0001 of one; admitted
  Float32 rounding drift is normalized. Raw model outputs have a separate explicit
  normalization initializer. This tolerance is a numerical admission policy, not
  calibrated identity evidence or a measured export-corpus result.
- The FEM2 codec requires exactly 2056 bytes before trusting its count, integer
  magic 0x46454D32, little-endian words, count 512, and valid normalized vectors.
  Unaligned buffers are supported. The magic bytes are 32 4d 45 46, not ASCII FEM2.
  Codec acceptance does not establish model or preprocessing compatibility.
- Galleries reject duplicate person IDs. Every example of every distinct person
  contributes to the best and runner-up decisions. No early perfect-match exit or
  acceptance-threshold filtering hides a competing identity. Ties are ambiguous,
  even with a zero configured gap. Exact distance cutoff is excluded; the gap and
  quality cutoffs are inclusive. Names remain literal data.
- Acceptance policy requires explicit distance, ambiguity gap, quality cutoff and
  missing-quality behavior. There are no production or purportedly calibrated
  defaults. Outcomes distinguish accepted, no-match, ambiguous, insufficient,
  unavailable and invalid quality. Similarity is not an identity probability.

## Provenance and companion coordination

The implementation is purpose-built against the documented wire/matching contract;
no companion source was copied. Pinned reference remains Photo Agent
`a7392e393ba584d8cc613e11562f967c4539d2b3`. Read-only comparison with committed
`e72ceef9a5ca10c00cf4d737676b1290c32b06b1` found no changes in KnownPerson,
EmbeddingCodec, KnownPeopleService, CoreMLFaceEmbedder or FaceRecognitionDefaults
across the intervening 30 commits. The v2 interchange is still absent: its v1.0
manifest does not bind embedding space, preprocessing, model, payload hashes or
stable library revision. Legacy imports remain an open integration gate.

The companion task was active in native QA with unrelated dirty source. Its
checkout was not modified and desktop use was deferred to avoid contention.
A coordination message records the exporter integration requirement; sending the
message does not prove agreement or implementation.

## Remaining gates

Atomic bounded archive/library admission, the companion exporter, detector and
alignment, verified installer, immutable runtime snapshots, inference queue and
cancellation, settings/UI, metadata writes and transfer integration remain to be
implemented. Gallery construction and synchronous matching currently have no
runtime workload limits; the importer and worker must impose measured count/byte
limits and cancellation boundaries before integration. macOS 14 execution,
authorized held-out real-face calibration and performance budgets are unverified.
No manual checklist result or human lane is advanced by synthetic vector tests.

## Validation and reviewed revision

Source commit: `e5ae9a76e3f662fba62567fe1b33255c163a1a01`, parent documentation `8a3cde9`.
Root integrated and committed the reviewed source unchanged after tests. Two
independent agents reviewed codec/matcher and all 13 new synthetic test groups;
no blocking finding remained. `git diff --check` passed.

Commands:

```sh
xcrun swiftc -typecheck -target arm64-apple-macosx14.0 -module-cache-path build/m4-matcher/module-cache AagedalFTPSync/Metadata/FaceRecognitionMatcher.swift AagedalFTPSync/Metadata/FaceRecognitionEmbeddingCodec.swift
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

All commands exited 0. Full suite: **1,028 discovered, 1,013 passed, 15 opt-in
skips, zero failures**, 46.562 seconds, completed 2026-09-12 11:25:58 +0200.
Runtime macOS 27.0 (26A428), arm64, Xcode 26.6 (17F113). The macOS 14 target
compiled; this does not establish macOS 14 runtime support.
Log `build/m4-matcher/full-tests.log`, SHA-256
`03c600a7e932beea44deff93909f36c3133659fe2f0c921eda560354f3862ec3`.
Result bundle:
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.12_11-24-58-+0200.xcresult`.

New development identity: `development-e5ae9a7-matching-foundation`, Debug version
2.9.2 build 37, status IMPLEMENTING. The six M4 manual cases were reviewed and
already cover the required behaviors; their semantics and 42 stable IDs are
unchanged. Human result file remains absent. No native or real-model pass claimed.

Next: implement the strict hash-bound library manifest and atomic snapshot store,
coordinate the companion exporter, then verified model lifecycle and bounded
image inference integration. Retain the separate real-model calibration gate.
