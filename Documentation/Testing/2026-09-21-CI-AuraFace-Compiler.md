# CI AuraFace test compilation — 2026-09-21

GitHub Actions run [35543428213](https://github.com/aagedal/Aagedal-FTP-Sync/actions/runs/35543428213)
failed at source `47df8140b1af0375f0bd5c087a18706864da6481` before executing tests.
The downloaded log identifies `AuraFaceRecognitionRuntimeTests.swift:20` (nested
Data/range/flatMap RGB construction exceeds type-checking limits) and line 41
(inferred `\.intValue` key-path root unavailable). CI selects Xcode 26.6 on
macOS 26; this local host has only Xcode 27.0 on macOS 27.0 (`26A428`).
Earlier successful local compilation therefore did not establish CI compatibility.

The RGB fixture now appends explicitly typed channel bytes in a loop. The input
is explicitly `MLMultiArray`, and its shape is converted into a named `[Int]`
using a closure. Channel values, interleaving, image dimensions and normalization
assertions are unchanged. No app behavior or CI checks are disabled or changed.
The separate checkout/Node.js deprecation warnings are not the compiler failure.

Validation source: `b36f91e` plus this test-only change. Commands:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

The application test target compiles, and the affected RGB input test passes.
The AuraFace class executes five tests: four passed, one opt-in skip, zero
failures. The full suite executes 1,266 tests with 25 opt-in skips and 52 failure
assertions (exit 65), all in storage/migration fixtures rejecting temporary paths
or their downstream startup assertions. The errors include `unsafeFile("/var")`,
`unsafePath` and `unsafeTemporaryDirectory`; this is separate from the test-only
RGB change. A second run with `TEST_RUNNER_TMPDIR` set to the workspace's disposable
`build/v3-ci-test-tmp/` still uses `/var` in these failures and produces the same
52 assertions. The override did not resolve the host's temporary-root behavior.
Neither full run is a pass. Security and development-identity checks pass. Local log: `build/v3-ci-compiler-fix-tests.log`; downloaded CI failure:
`build/v3-ci-failure-35543428213.log`.

Xcode 26.6 is unavailable locally. A successful GitHub rerun after the next push
is still required to confirm compatibility with its exact compiler. No remote
push or workflow rerun was performed by this change.

Second-run log: `build/v3-ci-compiler-fix-tests-canonical-tmp.log`. The storage-fixture temporary-root failures remain a separate validation issue to resolve.
