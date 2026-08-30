# Vendored SSH dependencies

These packages are source-vendored so Aagedal FTP Sync 2.6 can carry reviewed security fixes while preserving the fork-only SwiftNIO SSH APIs required by Citadel.

## Citadel

- Source: <https://github.com/orlandos-nl/Citadel>
- Baseline: tag `0.12.1`, commit `ae8562f895de06ccb86fdb1cbb65fd99c8976e12`
- License: `Citadel/LICENSE` (MIT)
- Local changes:
  - resolve `swift-nio-ssh` from `../swift-nio-ssh`;
  - require `swift-crypto` 4.5.1 or newer;
  - remove the unused `ColorizeSwift` example dependency and executable target.

## SwiftNIO SSH fork

- Source: <https://github.com/Wellz26/swift-nio-ssh>
- Baseline: tag `0.3.6`, commit `a05e6bbe6b141ee68da3030e00275504c0595d4d`
- License: `swift-nio-ssh/LICENSE.txt` (Apache 2.0)
- Local changes:
  - apply Apple's `31cdc3c` bounds check and its two regression tests for CVE-2026-43798;
  - require `swift-crypto` 4.5.1 through 4.x in every package manifest;
  - remove the unused documentation plugin dependency.

## Updating

1. Compare each local tree with its recorded baseline and the current upstream tag.
2. Reapply only the documented local changes; do not copy build output or `.git` directories.
3. Confirm Citadel still needs the fork-only algorithm registration APIs. Prefer Apple's official SwiftNIO SSH package once Citadel supports it.
4. Update commit IDs and the security baseline when the source changes.
5. Run the commands in the root `SECURITY.md`.
