# M4 face runtime extraction audit

Inspected the adjacent Photo Agent at source
`0556d321cd3cf2f04bf2b25c8ea090bf70d5b9fc` without modifying or launching it.
Production files were read from Git because that checkout has unrelated active work.

## Minimal extraction boundary

The reusable path is limited to Photo Agent's bounded, orientation-aware ImageIO
decode, Vision face detection and landmarks, two-eye ArcFace alignment, Core ML input
packing and embedding inference. FTP Sync must not import clustering, thumbnails,
clothing, sports, editor state or Known People persistence. It already has stricter
512-vector validation, FEM2 decoding, immutable galleries and explicit low,
unavailable and invalid-quality outcomes.

The intended operation contract is:

- decode an oriented image at no more than 4,096 pixels and retain the original
  oriented width for a 50-original-pixel face-width minimum;
- require Vision confidence 0.7, use capture quality when available, and preserve
  successful no-face separately from detection/inference failure;
- align image-left/right eyes to the 112-pixel ArcFace targets, with a bounded crop
  fallback when landmarks are unusable;
- pack normalized float32 NCHW input named `input`, require finite, nonzero output
  named `embedding` of exactly 512 values, then L2-normalize through FTP Sync's
  existing validated type;
- capture one verified compiled-model URL and one immutable people snapshot for a
  whole operation. Cancellation may suppress publication even when Vision or Core ML
  cannot stop inference immediately.

Source attribution must pin the extraction to the Photo Agent revision above and
retain the repository's GPL-3.0 obligations. The separate AuraFace notice identifies
AuraFace-v1 from fal.ai as Apache-2.0; this is repository evidence, not an independent
training-data or license audit.

## Model-contract discrepancy

Production recognition integration is blocked on one exact compatibility question.
The hash-pinned model file
`Aagedal Photo Agent/Resources/Models/AuraFaceR100.mlpackage/Data/com.apple.CoreML/model.mlmodel`
contains these metadata strings:

```text
Input 'input' 1x3x112x112 f32, BGR, (x-127.5)/127.5
torch==2.12.0
```

The tracked `bundled-components.json` contract declares RGB and Torch 2.8.0, while
`CoreMLFaceEmbedder.inputIsRGB` is `true` and packs RGB planes. The package's three
file hashes still match the tracked manifest. The existing converter's semantic
verification feeds numerical tensors, so it does not resolve image channel order.
Channel order changes the embedding space and cannot be inferred from a successful
shape/interface probe.

Photo Agent's coordinator was given the discrepancy and asked for a corrected,
versioned artifact/contract or a pinned reference-vector/labeled test that proves the
intended plane order. FTP Sync must not enable automatic identity publication or
claim companion embeddings compatible until that evidence exists.

## Installer boundary and remaining evidence

The clean Photo Agent installer baseline is
`a138f8d6f5415b506fd67549d935f6bfaefc4a96`. Reuse its strict signed descriptor and
package identity concepts, but replace its in-memory/default-redirect transport and
pre-admission `ditto` extraction. FTP Sync needs capped streaming, fixed HTTPS origins,
no redirects or credentials, archive-entry admission before extraction, cancellation,
crash-recoverable current/rollback state and an immutable verified URL publication.
Derived/re-downloadable model data belongs outside the strictly inventoried `v3`
store, under the app-owned Components directory.

A dedicated 32-byte Ed25519 model-distribution trust key is still required. Photo
Agent currently reuses its Sparkle public key; FTP Sync has no corresponding key.
Key selection and any re-signing must precede production installer publication.
Hosted ZIP installation, arm64 macOS 14 runtime, Intel support if retained,
authorized real-face calibration and cold/warm performance remain unverified.
