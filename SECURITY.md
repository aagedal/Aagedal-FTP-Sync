# Security policy

## Supported release

Security fixes are currently developed for the upcoming 2.6 release. Older builds should be upgraded when 2.6 becomes available.

Please report a suspected vulnerability privately to the repository owner rather than opening a public issue with exploit details. Include the affected version, protocol, reproduction steps, and any crash report that does not contain credentials or private file contents.

## Dependency security baseline

The 2.6 source tree deliberately vendors the SSH packages under `Vendor/` because Citadel 0.12.1 requires APIs from the Wellz26 SwiftNIO SSH fork that are not available in Apple's upstream package.

| Component | Baseline | Local security treatment |
| --- | --- | --- |
| Citadel | 0.12.1 (`ae8562f895de06ccb86fdb1cbb65fd99c8976e12`) | Uses the reviewed local SwiftNIO SSH package and requires Swift Crypto 4.5.1 or newer. The unused example dependency is removed. |
| Wellz26 SwiftNIO SSH | 0.3.6 (`a05e6bbe6b141ee68da3030e00275504c0595d4d`) | Carries Apple's exact bounds check from `31cdc3c` for CVE-2026-43798 / GHSA-998x-vgvp-xwpc, plus the upstream regression tests. |
| Swift Crypto | 4.5.1 | Resolves at 4.5.1 or newer to include the fix for CVE-2026-43823 / GHSA-8q93-f6xh-4f6f. |

The vendored copies retain their original license and attribution files. See `Vendor/README.md` before updating or replacing either package.

## Release checks

Run the security baseline guard and both test suites before shipping:

```sh
Scripts/check-security-baseline.sh

swift test \
  --package-path Vendor/swift-nio-ssh \
  --filter NIOSSHSignatureTests

xcodebuild test \
  -project AagedalFTPSync.xcodeproj \
  -scheme AagedalFTPSync \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

The Citadel and SwiftNIO SSH baselines require manual comparison with their upstream repositories because automated package tooling cannot safely update locally modified source.
