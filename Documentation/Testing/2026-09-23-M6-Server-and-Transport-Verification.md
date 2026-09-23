# 3.0 server and transport verification — 2026-09-23

Host: macOS 27.0, Xcode 27.0. The source identifies as 3.0.0 (38), a development build.

The disposable PHP/MariaDB metadata-calendar integration suite completed with
exit code 0. Its test container exited with code 0; the server and database
containers were then stopped and the Compose project was removed. This checks
the current server source, including protocol-2 and protocol-3 calendar paths,
but is not a deployed-server or archived-client test.

```sh
docker compose -p aftpsync-hosting-check \
  -f Server/MetadataSync/tests/compose.yaml \
  up --build --abort-on-container-exit --exit-code-from test
docker compose -p aftpsync-hosting-check \
  -f Server/MetadataSync/tests/compose.yaml down
```

The development release-identity guard, dependency security baseline, bundled
AuraFace source verification, and all five local checklist-server regression
tests also passed. The identity guard explicitly reported a development build.
The checklist tests required permission to bind a loopback HTTP port.

The loopback transport harness also passed all 16 focused integration tests
against live FTP, trusted implicit FTPS, and SFTP services. Cases cover
publication rollback, upload verification, cleanup races, changed source
retention, and programmed JPEG/synthetic-RAW plus XMP processing. The first
FTP cleanup test took 62 seconds; the full harness exited successfully and
checked that its seeded published files and staging roots remained intact.
The test bundle is in
`build/v3-remote-transport-sep23/Logs/Test/` (ignored local build output).

```sh
AFTPSYNC_TEST_DERIVED_DATA=build/v3-remote-transport-sep23 \
  build/3.0-benchmark-venv/bin/python \
  Scripts/run-remote-transport-tests.py
```

The transport services and checklist server required permission to bind
temporary loopback ports. The RAW fixture used by the transport harness is
synthetic and does not establish camera RAW integrity.

The vendored SwiftNIO SSH signature selection passed both regressions with
zero failures. The Debug app built by the transport harness passed the bundled
AuraFace app verification as well. Neither check establishes a signed Release
archive or supported-macOS runtime coverage.

```sh
swift test --package-path Vendor/swift-nio-ssh \
  --filter NIOSSHSignatureTests
python3 Tools/verify_bundled_auraface.py app \
  'build/v3-remote-transport-sep23/Build/Products/Debug/Aagedal FTP Sync.app'
```

```sh
Scripts/check-release-identity.sh
Scripts/check-security-baseline.sh
python3 Tools/verify_bundled_auraface.py source \
  AagedalFTPSync/Resources/Models/AuraFaceR100.mlpackage
python3 Scripts/test-3.0-checklist.py
```

These checks do not replace signed-candidate testing, macOS 14 runtime checks,
real-photo recognition, camera RAW/external-reader acceptance, or the final
manual checklist.
