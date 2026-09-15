# 2026-09-15 bundled AuraFace integration

The 3.0 app now compiles and ships one local `AuraFaceR100.mlmodelc` resource and
the separate `AuraFace-LICENSE.md` notice. Its source is the locally reviewed
Photo Agent `AuraFaceR100.mlpackage` conversion of
[fal/AuraFace-v1](https://huggingface.co/fal/AuraFace-v1), pinned to source revision
`af6d057c9b0ec4071d4c49c80e3539258798b609` and glintr100 ONNX hash
`a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60`.
The original conversion's source-file hashes and compiled weights are checked by
`Tools/verify_bundled_auraface.py`.

The 130,342,208-byte `weight.bin` cannot be a single ordinary GitHub blob. The
repository stores two 70 MB / 60 MB parts with pinned hashes; the shared Xcode
scheme reassembles them before Core ML's model-package dry run. A target build
phase checks all three `.mlpackage` files before compilation. The app bundle
validator checks required compiled files, the reviewed weight hash, the separate
license notice and absence of a duplicate raw package. Production startup loads
only the codesigned bundle resource and checks its weights and Core ML interface.
The download/install/removal UI is no longer part of the user flow.

Verification on the current arm64 macOS host:

- A focused recognition/installer test selection passed, including real bundled
  model load and embedding-contract identity.
- An unsigned Release build passed after removing the assembled `weight.bin`;
  source and app validators passed.
- A second unsigned Release scheme build began with neither `weight.bin` nor its
  parent weights directory, reconstructed the directory before Core ML inspected
  the package, and passed the source and app validators.

This does not claim metadata identity publication is production ready. The app's
acceptance-policy values remain deliberately absent until authorized held-out
real-face calibration; a compatible selected People Library, supported macOS
verification and a signed candidate build also remain required. Bundling removes
the user download dependency, not these admission checks.
