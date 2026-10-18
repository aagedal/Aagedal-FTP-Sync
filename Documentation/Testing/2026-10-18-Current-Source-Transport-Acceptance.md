# Current-source headless release checks — 2026-10-18

## Source and environment

Branch `t3/stabilize-v3-ui`, base commit `d660514`. The pending sidebar and live
shared-server refresh changes were present: `EndpointEditor.swift`,
`JobEditingSession.swift`, `JobsWindowView.swift`, `ServerProfileRepositoryTests.swift`
and `AagedalFTPSyncSmokeTests.swift` were modified. No app or test source changed
during this verification. The code/test diff is preserved in the ignored
`build/current-source-transport-source.patch`, SHA-256:
`4acaefe79aa92d2d10002030ccdcc28d6ff49b4045d3e02c8fce8dff23905d7c`.

Host: arm64 MacBook Pro, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a),
development app 3.0.0 (44). Python 3.13.16 uses an isolated ignored environment
at `build/transport-test-venv`, installed from the repository's pinned
`Scripts/delivery-latency-requirements.txt`: paramiko 5.0.0, pyftpdlib 2.2.0,
pyOpenSSL 26.4.0. The full installed version list is
`build/current-transport-python-freeze.txt`. No application dependency changed.

## FTP, implicit FTPS and SFTP

```sh
AFTPSYNC_TEST_DERIVED_DATA=build/continuation-tests \
  build/transport-test-venv/bin/python Scripts/run-remote-transport-tests.py
```

Exit 0. **All 16 live transport tests pass, zero failures or skips**, in 87.859
seconds according to the result summary. No runtime warnings are reported.
The script's post-test checks also verify original fault-file contents and no
remaining staging artifacts in its disposable roots before cleanup succeeds.

Coverage includes real localhost FTP, trusted implicit FTPS and pinned SFTP
uploads; preservation/cleanup after publication failure; upload-size verification;
untrusted-certificate and hostname rejection; cleanup/reconnect behavior; shared
server upload/download round trips; scheduled metadata delivery; late and
mid-processing RAW companion changes; and verified source-removal protection.
Fixtures use generated JPEG/synthetic RAW/XMP and test-only loopback credentials.
No user photos or external recipients are involved.

Result:
`build/continuation-tests/Logs/Test/Test-AagedalFTPSync-2026.10.18_17-54-36-+0200.xcresult`.
Summary: `build/current-source-transport-summary.json`.
Log: `build/current-source-transport.log`, SHA-256:
`704ab054fe0bdef9cc3dce92dc79226041a2b07fe3facd03448aaa9fec76faba`.

The initial restricted summary read failed because xcresulttool could not write
its temporary TestReport cache. The approved read succeeded; the test invocation
itself passed on its first run. No test was restarted for the reporting failure.

This is current-source correctness evidence, not a transport latency budget,
camera RAW/external-reader, supported-OS or native UI acceptance pass.

## Release tooling

- `python3 Scripts/test-build-candidate.py`: three tests pass, exit 0.
- `python3 Scripts/test-3.0-checklist.py`: five tests pass, exit 0; log
  `build/current-checklist-tests.log`.
- `python3 Scripts/test_verify_raw_xmp_integrity.py`: ten contract tests pass,
  exit 0; log `build/current-integrity-verifier-tests.log`. These test verifier
  behavior and do not constitute an actual external-reader image check.

Checklist tests use only temporary private state files and localhost listeners.
The historical candidate and any real user result lanes were not modified.

## Remaining gates

PHP/MariaDB integration was not run: the Docker client is present, but the local
OrbStack daemon socket is absent. No desktop application was started to repair
that prerequisite while the user requested waiting before desktop use.

The three prepared setup native cases remain unexecuted. The unsigned hosted
transport build changes DEBUG signing, so the final signed native build was
restored without launching native tests (`build/current-source-ui-ready.log`,
exit 0). The DEBUG app passes strict deep signature verification. The broader M0–M6
requirements and final-candidate acceptance remain open; the historical candidate
stays IMPLEMENTING.
