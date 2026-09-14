# M3 recovery fixtures and non-UI verification — 2026-09-14

Implementation commit: `ade3c2d`. This is development evidence, not a beta or
release candidate. No SwiftUI/UI test result is claimed in this checkpoint.

## Change reviewed

The startup UI fixture support now prepares damaged-primary and interrupted
PREPARED migrations in addition to the populated and backup-only inventories.
The prepared fixture freezes the valid snapshot, then changes the legacy job so
the eventual recovery assertion can prove that recovery does not re-import later
legacy writes. Metadata timeline clips also expose their full interactive frame,
label, value, hint and edit action as one accessible control.

## Non-UI verification

The focused version 3 startup, bootstrap, source-catalog, migration-driver,
storage-lease and startup-path selection passed with 49 declared tests and zero
failures:

```sh
xcodebuild -quiet test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/v3-nonui-verification CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO \
  -only-testing:AagedalFTPSyncTests/Version3StartupControllerTests \
  -only-testing:AagedalFTPSyncTests/Version3BootstrapCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/Version3MigrationSourceCatalogTests \
  -only-testing:AagedalFTPSyncTests/Version3MigrationDriverTests \
  -only-testing:AagedalFTPSyncTests/Version3StorageLeaseTests \
  -only-testing:AagedalFTPSyncTests/Version3StartupPathsTests
```

The security dependency baseline, unchanged 2.9.2 (37) identity guard and all
five checklist persistence/isolation tests passed. The patched vendored
`NIOSSHSignatureTests` selection passed both oversized-ECDSA rejection tests.

An unsigned arm64 Release build completed at
`build/v3-nonui-release/Build/Products/Release/AagedalFTPSync.app`. Its executable
SHA-256 is `d2fb5c963a6172d814f7aad85fecafaa186726a9daa964bb28b7ba10b2a24c18`.

## Unverified boundary

The signed UI suite was stopped without a result and was not retried, following
the instruction not to run SwiftUI tests. Consequently the new damaged-primary
and prepared-recovery UI cases, timeline accessibility behavior and the complete
signed UI suite remain open. PHP is unavailable on this host, so the PHP/MySQL
protocol suite was not rerun. No production face distribution, actual-face,
supported-OS, signed archive or manual checklist gate advanced.
