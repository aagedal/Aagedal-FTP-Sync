# 2026-09-15 bundled AuraFace assembly safety

At source base `5b2bea7eff7500fdd5bd3467210e89ebbfff262a` on arm64 macOS 27.0,
the model build helper was changed to assemble into a same-directory temporary file,
flush and hash it, then atomically replace the destination. A failed assembly or
replace now leaves any existing destination untouched and removes only its temporary
file. The helper also rejects linked source and destination directories. The source
and app validators now require the reviewed separate license notice hash
`afc3817e2bb55caedb5fdcb30b0daf786261f0295cb3f1bac3d793ec58961131`.

Verification at that base plus the three owned tool-file changes:

- `/usr/bin/python3 Tools/test_prepare_bundled_auraface.py`: 5/5 pass, including
  injected replace failure, tampered source part and linked destination directory.
- `/usr/bin/python3 Tools/prepare_bundled_auraface.py`: exit 0 against the existing
  130,342,208-byte assembled local weights.
- `/usr/bin/python3 Tools/verify_bundled_auraface.py source AagedalFTPSync/Resources/Models/AuraFaceR100.mlpackage`:
  exit 0; reviewed package files, weight hash and license notice match.
- `git diff --check`: exit 0.

The checkout also contained unrelated uncommitted Xcode project, scheme and string
catalog edits throughout this check; they were not changed or staged here. The
tracked development candidate's app predates the bundled-model change and does not
contain `AuraFaceR100.mlmodelc`, so it was not used as app-bundle evidence. A fresh
signed candidate-source build, supported-OS model load and real-face calibration
remain release gates.
