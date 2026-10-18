# Current vendored SSH signature regressions — 2026-10-18

The required `NIOSSHSignatureTests` selection from `SECURITY.md` passes on current
source: **two tests, zero failures or skips**, exit 0. The tests reject an oversized
ECDSA R component and an oversized S component as invalid SSH messages. This is
the required bounds-regression check, not a general SSH security audit or native
SFTP acceptance pass.

## Isolation and dependency identity

Base commit: `009d761`, with the existing pending setup changes present. Vendored
source and application dependencies were not modified. An isolated copy of
`Vendor/swift-nio-ssh` was placed in ignored `build/ssh-signature-package`; all
128 source/package files match the original byte for byte. Its file/digest manifest
is `build/current-ssh-package-manifest.sha256`, SHA-256:
`35130ffc0b1ef8a5a8f17fdf49fbd9d0509b8098a5b1d4aecca82391cea974b7`.

The app's complete `Package.resolved` was copied into that isolated package and
remained unchanged after the run (SHA-256
`e7cd9a5be62d333641a51199a7aa7f333ecf06f4a0a2a5c14b86badb8cb867da`).
Every checkout in the isolated SwiftPM workspace matches its app-lock revision.
Relevant versions include Swift Crypto 4.5.1, SwiftNIO 2.101.3, Swift Atomics 1.3.1,
Swift Collections 1.6.0 and Swift System 1.8.1. No dependency upgrade was performed.

```sh
swift test --package-path build/ssh-signature-package \
  --scratch-path build/ssh-signature-tests \
  --disable-automatic-resolution --skip-update --filter NIOSSHSignatureTests
```

The selected suite completes in 0.006 seconds after compilation. Toolchain:
Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), arm64 macOS 27.0.1, Xcode 27.0.
The log records existing vendored concurrency/redundant-modifier warnings and the
deprecated `--skip-update` option; this is not a warning-free strict Swift 6 language
migration. No vendored code was changed to suppress those diagnostics.

Log: `build/current-ssh-signature-tests.log`, SHA-256
`9d5abd2c6e3d48db690fb45f2599b491a3722005fa1d137b5706e49a66b2fe39`.
`Scripts/check-security-baseline.sh` passes; `git diff -- Vendor` is empty.

All work is headless. No desktop/native interaction was attempted, following the
user's wait. Current hosted/burst/scale evidence remains separate from supported-OS,
native UI/VoiceOver, original camera media, PHP/MariaDB and final signed-candidate
acceptance. The historical candidate and user acceptance result lanes were not changed.
