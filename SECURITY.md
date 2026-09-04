# Security policy

## Supported release

Security fixes are currently developed for the 2.7 release line and the next feature release. Older builds should be upgraded to the latest available 2.7.x version.

Please report a suspected vulnerability privately to the repository owner rather than opening a public issue with exploit details. Include the affected version, protocol, reproduction steps, and any crash report that does not contain credentials or private file contents.

## Dependency security baseline

The 2.7 source tree deliberately vendors the SSH packages under `Vendor/` because Citadel 0.12.1 requires APIs from the Wellz26 SwiftNIO SSH fork that are not available in Apple's upstream package.

| Component | Baseline | Local security treatment |
| --- | --- | --- |
| Citadel | 0.12.1 (`ae8562f895de06ccb86fdb1cbb65fd99c8976e12`) | Uses the reviewed local SwiftNIO SSH package and requires Swift Crypto 4.5.1 or newer. The unused example dependency is removed. |
| Wellz26 SwiftNIO SSH | 0.3.6 (`a05e6bbe6b141ee68da3030e00275504c0595d4d`) | Carries Apple's exact bounds check from `31cdc3c` for CVE-2026-43798 / GHSA-998x-vgvp-xwpc, plus the upstream regression tests. |
| Swift Crypto | 4.5.1 | Resolves at 4.5.1 or newer to include the fix for CVE-2026-43823 / GHSA-8q93-f6xh-4f6f. |

The vendored copies retain their original license and attribution files. See `Vendor/README.md` before updating or replacing either package.

## Release checks

Run the security baseline guard and all test suites before shipping:

```sh
Scripts/check-security-baseline.sh

swift test \
  --package-path Vendor/swift-nio-ssh \
  --filter NIOSSHSignatureTests

xcodebuild test \
  -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO

# Requires a configured development signing identity.
xcodebuild test \
  -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests \
  -destination 'platform=macOS'
```

The Citadel and SwiftNIO SSH baselines require manual comparison with their upstream repositories because automated package tooling cannot safely update locally modified source.

## Configuration package security

The `.aftpsync` extension identifies an Aagedal FTP Sync configuration package; the extension itself is not a security boundary. Encryption is enabled by default but can be explicitly turned off. Encrypted package contents use AES-256-GCM authenticated encryption. A 256-bit key is derived from a user password of at least 12 characters using PBKDF2-HMAC-SHA256 with a random 128-bit salt and 600,000 iterations. Unencrypted packages can expose server addresses, usernames, paths, and editorial metadata, and the export UI warns about this before saving.

Exports deliberately omit passwords stored in Keychain and machine-bound security-scoped folder bookmarks. Referenced server profiles are included with fresh profile and credential identifiers so their job relationships remain portable without carrying secrets. Imports create disabled jobs with fresh job and credential identifiers, and users must grant folder access and enter server passwords again. The importer rejects oversized files, unsupported or excessive key-derivation parameters, inconsistent package scopes, authentication failures, and malformed contents.
