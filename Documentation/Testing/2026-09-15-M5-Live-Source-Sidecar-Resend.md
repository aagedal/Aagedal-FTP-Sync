# M5 live source-sidecar resend — 2026-09-15

Test base: `fe271ab2f54e9c4af8dfc9dbd88450e835232238` on
`codex/version-3-0-plan`. The focused run used the equivalent one-file
uncommitted test diff; the worktree was dirty during execution. Host: macOS
27.0 (`26A428`), arm64. The app implementation and tracked development
candidate remain unchanged at `9f04fad` and 2.9.2 (37).

The disposable programmed-media fixture creates a decodable JPEG with GPS, an
opaque `.CR3` primary and a valid XMP sidecar. It runs an activated download
twice, then changes only the remote XMP companion's source subject array and
modification time. On FTP, trusted implicit FTPS and SFTP, the next run sends
the changed RAW companion and reports an applied metadata outcome only for the
RAW primary. The delivered sidecar retains both source keywords and the
resolved Headline. The JPEG output is byte-identical, the RAW payload is
byte-identical, and a following poll transfers nothing. The existing changed-
template preview, explicit reprocessing and reviewed local sidecar-conflict
checks continue in the same fixture.

`AFTPSYNC_TEST_DERIVED_DATA=build/v3-reviewed-edits
AFTPSYNC_REMOTE_ONLY_TESTING=AagedalFTPSyncTests/RemoteTransportIntegrationTests/testProgrammedDownloadProcessesDecodableJPEGAndValidRAWSidecarAcrossLiveTransports
build/3.0-benchmark-venv/bin/python Scripts/run-remote-transport-tests.py`
passed the one focused XCTest with exit 0 after running the three localhost
services. Result bundle:
`build/v3-reviewed-edits/Logs/Test/Test-AagedalFTPSync-2026.09.15_14-58-22-+0200.xcresult`.
`git diff --check`, `Scripts/check-security-baseline.sh` and
`Scripts/check-release-identity.sh` also passed.

The first attempt failed only because the fixture reused and mutated its source
XMP file across transports, accumulating the new keyword. The fixture now
starts each transport change from the original XMP value; the corrected run
passes. This verifies a changed source companion against disposable live
transports. The `.CR3` bytes are synthetic, so camera RAW decoding, native UI,
supported-OS operation and the complete M5 matrix remain open.
