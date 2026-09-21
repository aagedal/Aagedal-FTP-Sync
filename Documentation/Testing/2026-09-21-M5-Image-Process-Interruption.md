# Image publication process interruption — 2026-09-21

Source: `0674efe` plus the test/harness changes committed with this report on
`codex/version-3-0-plan`. Host: arm64 macOS 27.0 (`26A428`), Xcode 27.0
(`27A266a`). Development app identity: 3.0.0 (38). Application code and the
historical candidate identity are unchanged. No private checklist results file
was present; no human acceptance entries were modified.

## Scope

The process-interruption harness now runs separate generated JPEG and synthetic
RAW/valid-XMP transactions in ordinary and managed `Synced Files` destinations.
Each has four SIGKILL boundaries: prepared, originals held, output published and
before commit. Publication deliberately remains one image and its optional sidecar
per transaction. The JPEG is encoded from generated pixels; its original and
processed Headline are written through the production metadata writer. RAW bytes
are an explicitly synthetic opaque payload, not a camera file.

Every fresh recovery host validates the retained manifest's paths, replacement
flags, original snapshots, held bytes and output snapshots. It checks expected
visible-file presence and contents before reconciliation, and requires fresh
admission to reject the retained transaction. Explicit fixture reconciliation
keeps an already published output and restores missing originals, including the
unchanged guard-only RAW. File modification dates survive this operation.

For JPEG, the original and processed compressed image scan data are identical;
ImageIO independently decodes the reconciled image and reads its expected IPTC
Headline. For RAW/XMP, strict sidecar parsing reads the expected Headline.
After recovery-directory removal, a fresh byte-matched publication succeeds,
with expected bytes and metadata and no retained transaction. Both the signal
failure and exact phase marker are required from each worker; every recovery
host must exit successfully and write its completion marker.

## Verification

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  CODE_SIGNING_ALLOWED=NO
python3 Scripts/test-metadata-process-interruption.py \
  build/v3-preview-consistency/Build/Products/AagedalFTPSync_macosx27.0-arm64.xctestrun
python3 -m py_compile Scripts/test-metadata-process-interruption.py
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

Focused hosted selection: 27 executed, 23 passed, four opt-in skips, no failures,
exit 0. Log: `build/v3-image-interruption-focused.log`. The opt-in interruption
workers run separately through the harness, not as ordinary hosted tests.
Hosted result bundle:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.21_16-42-18-+0200.xcresult`.
App: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.
App-code debug dylib SHA-256:
`a225f659f5771affe7d23c7f20b320c76eb0a1bdcfa43d5248c6a10f0a7bb5e2`.
Hosted test executable SHA-256:
`12ce027907b00ac97a4451508a46f5f6b07157ca3992803a0783e4be7dc8e70b`.
Python syntax, security/development-identity guards and diff checks pass.

Harness: all 16 interruption/recovery pairs pass, exit 0. Each of the 16
workers reports only the expected SIGKILL failure (Xcode exit 65); each fresh
recovery host exits 0. Evidence: `build/aagedal-interruption-biuiovi2/`, with
32 per-role logs/result bundles and `results.json`. Console log:
`build/v3-image-interruption-harness.log`.

An initial combined JPEG/RAW fixture was correctly rejected by the production
one-image/optional-sidecar admission guard, before reaching SIGKILL. It is not
passing interruption evidence. The corrected matrix uses separate transactions.
The initial restricted build could not write compiler/package caches; approved
Xcode invocations succeeded.

## Remaining gates

This extends controlled process-interruption evidence for the publication
primitive. It is not native UI reconciliation, end-to-end job interruption,
automatic recovery replay, power-loss durability, camera RAW decoding or a
supported-OS release pass. Photo Agent was active on the shared desktop, so no
computer-use/UI automation was performed. Native scoped Programming/conflict
workflows, camera RAW, production face calibration and remaining release gates
stay open. No milestone or required final-candidate checklist case is closed.
