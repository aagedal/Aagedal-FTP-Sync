# BigInt Xcode 27 manifest compatibility

Date: 2026-09-12
App-code commit: `3ba4070be64d4d7d0904cc535aff8c0e554a2d05`
Machine: MacBook Pro (Mac17,8), Apple M5 Pro, 64 GB
Operating system: macOS 27.0 (26A428)

## Scope

Xcode 27 warns when evaluating BigInt 5.7.0's Swift package manifest because it
declares watchOS 4, while watchOS 9 is now the oldest supported deployment target.
BigInt is a transitive dependency of the vendored Citadel package. The warning is
tracked upstream in [BigInt issue #135](https://github.com/attaswift/BigInt/issues/135),
and the available BigInt 6.0.1 manifest still declares watchOS 4.

The exact resolved BigInt 5.7.0 source at revision
`e07e00fa1fd435143a2dcf8b7eec9a7710b2fdfe` is now pinned in `Vendor/BigInt`.
Citadel resolves that local package instead of downloading a second copy. The only
semantic manifest change is `.watchOS(.v4)` to `.watchOS(.v9)`; the source tokens
and upstream MIT license are unchanged. Imported trailing whitespace was normalized.
`Vendor/BigInt/UPSTREAM.md` records the permanent provenance.

The app remains a macOS application. This dependency-manifest adjustment does not
change the app's deployment target or enable a watchOS product.

## Verification

The dependency guard passed and now rejects a return to the remote BigInt package
or a watchOS target below 9:

```sh
sh Scripts/check-security-baseline.sh
```

Citadel's key tests passed against the local BigInt package:

```sh
swift test --package-path Vendor/Citadel --filter KeyTests
```

Result: 9 tests passed with zero failures. Existing Citadel and SwiftNIOSSH
concurrency/deprecation diagnostics remain, but the BigInt watchOS warning did not
appear.

An unsigned Debug build passed after resolving BigInt locally:

```sh
xcodebuild build -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-face-runtime-build \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO
```

An unsigned Release build then passed from a detached, exact-clean worktree at the
recorded commit:

```sh
xcodebuild build -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-face-runtime-release \
  CODE_SIGNING_ALLOWED=NO
```

Result: `** BUILD SUCCEEDED **`. Both builds resolved BigInt from `Vendor/BigInt`;
neither emitted the reported watchOS 4 deprecation warning.

Release app:
`build/DerivedData-face-runtime-release/Build/Products/Release/AagedalFTPSync.app`
