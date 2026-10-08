# M5 remote source change during processing — 2026-09-15

Test source: clean base `2f84270655a4db136dc7336b03593609db1911fb`
plus the focused `RemoteTransportIntegrationTests.swift` interval on
`codex/version-3-0-plan`. Host: arm64, macOS 27.0 (`26A428`), Xcode 27.0
(`27A266a`). This remains 2.9.2 (37) development source, not a release candidate.

The opt-in fixture imports a synthetic opaque `.CR3` and a valid GPS-bearing XMP
companion to each disposable FTP, trusted implicit FTPS and SFTP server. During
the first run's injected geocoding lookup, it overwrites the remote sidecar with
a different Headline of exactly the same byte count and the same advertised
modification date. The source snapshot is already read at this point.

For all three transports, the first run reports no processed publication. The
processed folder is empty, while the remote RAW and updated XMP remain. A retry
publishes the updated sidecar alongside the unchanged opaque RAW bytes, then
removes both remote source files. The fixture also checks for leftover transport
staging files. This verifies the `97a0723` pre-publication source comparison on
remote processed-folder paths, including a size/date-neutral source mutation.

Focused command (exit 0, 1 XCTest method spanning three transports):

`AFTPSYNC_REMOTE_ONLY_TESTING=AagedalFTPSyncTests/RemoteTransportIntegrationTests/testRemoteRAWSidecarChangedDuringGeocodingDoesNotPublishProcessedPair AFTPSYNC_TEST_DERIVED_DATA=build/v3-remote-source-mutation build/3.0-benchmark-venv/bin/python Scripts/run-remote-transport-tests.py`

Result bundle: `build/v3-remote-source-mutation/Logs/Test/Test-AagedalFTPSync-2026.09.15_17-45-55-+0200.xcresult`.
`git diff --check`, `Scripts/check-security-baseline.sh` and
`Scripts/check-release-identity.sh` pass. The initial run used the system Python
without pinned fixture dependencies; the next run found the sandbox's socket
restriction. The authorized elevated retry used the existing pinned local
virtualenv and completed the test. No production server or user photo was used.

The fixture does not decode the RAW payload, exercise the native UI, establish
external-reader metadata compatibility, or measure the extra remote source read
under an enriched burst. Those gates, supported-OS checks, and the full M5
correctness matrix remain open.
