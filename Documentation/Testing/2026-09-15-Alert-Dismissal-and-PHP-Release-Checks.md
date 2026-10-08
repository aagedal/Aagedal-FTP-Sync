# Jobs alert dismissal and protocol-3 server release checks

Date: 2026-09-15  
App-code commit: `5440e77c26cf8a5654dbf861e9cc48bebfa472fa`  
Host: macOS 27.0 (`26A428`), arm64 MacBook Pro, Xcode 27.0 (`27A266a`)

## Jobs alert diagnostic

The preceding complete signed UI result at `5944d5b` passed 18/18 but recorded
SwiftUI's "Publishing changes from within view updates" warning in
`testRecoversAfterVisibleSaveFailure()`. The Jobs window's custom alert presentation
binding synchronously cleared `AppStore.alertMessage` when SwiftUI wrote `false`.
The setter now defers that clear until the view update ends and compares the dismissed
message before clearing, so a newer alert is retained. The explicit OK button still
clears the message immediately.

Focused signed UI command:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/v3-alert-binding-ui -parallel-testing-enabled NO \
  -only-testing:AagedalFTPSyncUITests/AagedalFTPSyncSmokeTests/testRecoversAfterVisibleSaveFailure
```

Exit 0; one test passed, zero failed or skipped. The new result's runtime-warning
nodes contain only Xcode's existing quality-of-service priority-inversion diagnostic;
the SwiftUI view-update warning is absent. Result:
`build/v3-alert-binding-ui/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.15_11-02-59-+0200.xcresult`.
This focused result verifies the warning fix; the unchanged broader 18-test result
at `5944d5b` remains the most recent complete UI suite.

## PHP/MariaDB suite

Disposable Docker Compose project with an internal-only network, test credentials
and a tmpfs MariaDB 11.4 database:

```sh
docker compose -p aftpsync-v3-evidence-20260915 \
  -f Server/MetadataSync/tests/compose.yaml up --build \
  --abort-on-container-exit --exit-code-from test
```

Exit 0. The captured log contains 162 PASS assertions and final passing hosting,
live-sync, concurrent namespace-creation and template-namespace summaries. It covers
legacy-server isolation/rollback against the upgraded disposable database. Server
and legacy-server exit 137 appears only during Compose's expected abort-on-test-exit
shutdown; the test container exited 0. `docker compose ... down -v` then removed this
project's containers, network and temporary database. Log:
`build/v3-php-server-20260915.log`, SHA-256
`d1bce607c6677eff4005d634b5df6629a19fc85b0592a78b9e1ec5bebb046056`.
This does not establish a native linked-calendar UI or live production-server pass.

## Other checks and development binary

- `Scripts/check-security-baseline.sh`: exit 0.
- `Scripts/check-release-identity.sh`: exit 0 for the unchanged 2.9.2 (37) identity.
- `python3 Scripts/test-3.0-checklist.py`: five tests passed after loopback bind
  access was available. The first sandboxed attempt could not bind 127.0.0.1 and
  ran no meaningful HTTP assertions; the rerun passed all five.
- Unsigned arm64 Release build of `5440e77`: exit 0 after Xcode cache access was
  available. The first workspace-sandbox attempt exited 74 because SwiftPM could not
  write its machine-local compiler/manifest caches; the rerun compiled successfully.
- Release app:
  `build/v3-alert-binding-ui/Build/Products/Release/AagedalFTPSync.app`.
  Executable SHA-256:
  `66f1c3342bad88b6a1e3651d1895ad0f18177d401e05c2920bcffdf66eec1a95`.

The release app is unsigned and still reports 2.9.2 (37). It is a development build,
not a beta or 3.0 release candidate. The complete non-UI suite and 18-test signed UI
suite at `5944d5b` preceded the alert fix; a complete candidate-source rerun remains
necessary before either release tier.
