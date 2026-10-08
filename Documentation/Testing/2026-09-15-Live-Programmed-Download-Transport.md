# Live programmed-download transport check — 2026-09-15

Test source: `6b3728953f89ae3c3dd81050475dd4137add75aa` on
`codex/version-3-0-plan`. The app implementation remains `9f04fad`; this
checkpoint adds one opt-in integration test and does not create a new app
candidate. The run used disposable localhost FTP, trusted implicit FTPS and
SFTP services, isolated remote roots and local folders on macOS 27.0
(`26A428`), arm64. All filenames and content were synthetic.

`AFTPSYNC_TEST_DERIVED_DATA=build/v3-alert-binding-ui
build/3.0-benchmark-venv/bin/python Scripts/run-remote-transport-tests.py`
passed 13/13 tests, including the new three-transport case. The ignored run
log is `build/v3-programmed-filter-live-transport.log`.

For each transport, a first run selected a photographer's RAW and XMP sidecar,
and verified both destination files and their exact bytes. Changing the saved
programming track selected a second photographer's JPG on the next run while
leaving the earlier local files intact. Clearing the day selected no new files.
An `_EDITED` returned copy remained excluded throughout. The fixture removed
its own remote files and the suite's staging-cleanliness assertions passed.

The first attempt without localhost socket access stopped before starting the
services with `Operation not permitted`. An authorized sandbox escalation ran
the same disposable loopback suite. Its first XCTest run showed that the early
download path counts a RAW/sidecar group once while the full-listing path may
count its files separately; both delivered the expected bytes. The test now
asserts actual files and content and treats the transfer count only as evidence
that work occurred. The corrected suite passed.

This closes the filter-specific live transport check. Synthetic RAW/XMP bytes
do not prove actual-media metadata processing, supported-macOS operation or a
versioned signed 3.0 beta; those acceptance gates remain open.
