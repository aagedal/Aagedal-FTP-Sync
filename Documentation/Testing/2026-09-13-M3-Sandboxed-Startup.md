# M3 sandboxed first startup verification — 2026-09-13

Implementation commit: `21e9ed2`. This is native development evidence, not a
signed release-candidate or complete migration acceptance pass.

## Native finding and correction

A current Debug build was given the unique QA bundle identifier
`no.aagedal.FTPSync.Release3QA`, ad-hoc signed, and launched without UI-test mode. Its
Application Support root was therefore isolated at:

```text
/Users/truls.aagedal/Library/Containers/no.aagedal.FTPSync.Release3QA/Data/Library/Application Support/AagedalFTPSync
```

The first observable launch showed all nine JSON-library choices and original-history
choice as absent, left **Prepare 3.0 Copy** disabled until the explicit other-copies
acknowledgement, and displayed the isolated root. After acknowledgement, the pre-fix
build failed closed at `Stage: lease` with `unsafeRoot`. No default app session opened.

The lease previously opened `/` and walked every ancestor with `openat`. App Sandbox
can authorize the complete container path while denying independent descriptors for
ancestors such as `/Users`, so the walk rejected a normal application container. The
corrected lease requires an absolute, already-physical path, rejects a symlink at the
final component, opens that complete path, and compares the named/opened device and
inode. Existing lock-file `O_NOFOLLOW`, single-link, identity and lifetime checks remain.
The existing ancestor-alias, final-symlink, root-replacement, lock-replacement,
hard-link, directory and FIFO rejection tests continue to pass.

The rebuilt QA app then repeated the same empty-source workflow successfully. After
acknowledgement and **Prepare 3.0 Copy**, the startup window showed **Review before
starting**, stated that jobs and calendar sync remain paused, and exposed the explicit
**Start Calendar Sync** action. Opening the Jobs window showed no jobs, calendar sync
paused, and Startup and Recovery navigation. Creating a disposable draft exposed the
geocoding, fixed processing-zone, face-recognition, people-library and source-removal
controls without enabling a transfer. People Library settings showed no selected
library and the expected fail-closed message, “Model downloads are not configured in
this build.” No production model, network endpoint, user photo, credential or installed
app data was used.

QA app:
`build/qa-20260913/Build/Products/Debug/AagedalFTPSync.app`

- executable SHA-256: `f2cd76ce3c450aa1109dd6f28d65a84090dab67063eb4f10dc0ba25e9166751a`
- strict deep code-signature verification: passed (ad-hoc “Sign to Run Locally”)
- observed host: macOS 27.0 (26A428), Apple silicon; Xcode 27.0 (27A266a)

The QA app was quit after observation. This unique bundle's disposable sandbox data
is not candidate data and was not added to the checklist's user lane.

## Automated verification

The focused startup/storage selection ran 32 tests with zero failures. The unchanged
implementation source then ran the complete application suite:

- 1,142 discovered;
- 1,126 passed;
- 16 opt-in integration tests skipped;
- zero failures.

Command:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/startup-sandbox-fix \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Result bundle:
`build/startup-sandbox-fix/Logs/Test/Test-AagedalFTPSync-2026.09.13_19-31-48-+0200.xcresult`.
The security baseline and current 2.9.2 (37) identity guard passed. An unsigned arm64
Release build passed at
`build/startup-sandbox-fix-release/Build/Products/Release/AagedalFTPSync.app`;
its executable SHA-256 is
`edd5dc76fda992c74f6934957779feb766f656623746bfdf5558c2a7c8865f80`.

## Remaining boundary

This closes the sandbox-specific first-run failure and provides native evidence for an
empty migration plus paused post-migration UI. It does not pass the complete `m3-001`
case: an isolated populated 2.9 store, damaged-primary/backup choices, prepared
recovery, second-copy exclusion, downgrade restoration and relaunch persistence still
need native observation. Activated variable editors, real transfers, signed UI tests,
supported macOS 14 execution and the live protocol-3 server/client matrix also remain
open.
