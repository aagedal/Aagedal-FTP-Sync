# Metadata Programming server filename filter — 2026-09-15

Source: `9f04fade20ac19777af89d2c6ee1d5df5633f638` on
`codex/version-3-0-plan`. Tests ran on macOS 27.0 (`26A428`), arm64, with
disposable local folders, a fake server session and an isolated signed UI-test
profile. The working tree was clean after the implementation commit.

One-way server-to-local jobs can opt in to derive filename prefixes from the
photographers selected on the current Metadata Programming day. Overlapping
clips cover older programming without day tracks. Each sync freezes its selection
before listing files, so an edited day takes effect on the next run. A day without
assigned photographers selects no files. Existing jobs retain manual initials.
Filename exclusions still take priority, and historical assignments are retained
for local cleanup and explicit reprocessing. A jobs/package export with the option
requires format 3; mislabeled format 1/2 packages fail preflight instead of
silently losing the choice. The run-local prefix snapshot is never encoded.

Verification:

- `xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync
  -configuration Debug -destination 'platform=macOS,arch=arm64'
  -derivedDataPath build/v3-alert-binding-ui -parallel-testing-enabled NO
  '-only-testing:AagedalFTPSyncTests' CODE_SIGNING_ALLOWED=NO` passed:
  1,151 executed, 16 opt-in skips, zero failures. Log:
  `build/v3-programmed-filter-full-nonui.log`. This ran with the final
  model/transfer/sync implementation in the working tree, before the UI-only
  confirmation duration and version-3 UI fixture change.
- The focused `ConfigurationTransferActivationTests` and
  `ConfigurationTransferTests` selection passed 26/26, including format-3
  round-trip and format-2 mismatch rejection. Log:
  `build/v3-programmed-filter-transfer.log`.
- `DownloadNamingTests` passed 28/28 after the fake-server end-to-end test was
  added. It covers same-folder `_EDITED` exclusions, day changes, empty days,
  and completed-directory/full-listing selection with RAW/XMP companions. Log:
  `build/v3-programmed-filter-integration.log`.
- The signed `AagedalFTPSyncUISmokeTests` focused test passed after an isolated
  2.9-to-3.0 migration, opening a remote download job, enabling the option and
  saving it in version-3 storage. Log: `build/v3-programmed-filter-v3-ui.log`;
  1 test, 25.000 seconds, zero failures. Earlier fixture attempts used legacy
  storage, which the new version guard correctly rejects, and one retry stopped
  at macOS's menu-bar-only scene launch. Those runs are not counted as passes.
- `Scripts/check-security-baseline.sh` and
  `Scripts/check-release-identity.sh` passed. The latter confirms the app remains
  2.9.2 (build 37), so this is a development build. The unchanged disposable
  PHP/MariaDB suite last passed 162 assertions at `5440e77`.
- `xcodebuild build -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync
  -configuration Release -destination 'platform=macOS,arch=arm64'
  -derivedDataPath build/v3-programmed-filter-release CODE_SIGNING_ALLOWED=NO`
  passed. The separate unsigned arm64 app is at
  `build/v3-programmed-filter-release/Build/Products/Release/AagedalFTPSync.app`.
  Its executable SHA-256 is
  `3f62340cb2f83c59ac3c805c6a152bc25c2036c135f1dda021445da9bb310628`.
  Log: `build/v3-programmed-filter-release.log`.
- `AFTPSYNC_TEST_DERIVED_DATA=build/v3-alert-binding-ui
  build/3.0-benchmark-venv/bin/python Scripts/run-remote-transport-tests.py`
  passed all 12 opt-in loopback transport cases across FTP, trusted implicit FTPS
  and SFTP. The venv contains the exact pinned fixture versions: paramiko 5.0.0,
  pyftpdlib 2.2.0 and pyOpenSSL 26.4.0. Log:
  `build/v3-programmed-filter-transport.log`. The first attempt with the system
  Python stopped before starting services because those packages were absent;
  the existing pinned venv resolved it. The 12-case suite checks shared-server
  naming/exclusions and transport rollback, but does not yet exercise the new
  programming-derived prefix choice against a live server.

The production-model, actual-media, supported-macOS, native protocol-3 calendar,
performance and release identity gates in `3.0-Readiness.md` remain open. This
filter's live-server-specific programming selection remains a beta check; the fake
server test verifies the selection logic and download path, while the loopback
  suite verifies the existing transport composition.
- The new tracked development-candidate record uses a unique id and the exact
  `9f04fad` source, app path and executable digest. JSON validation and a direct
  candidate commit/digest comparison passed. The five checklist-server tests
  passed with local-loopback access (`build/v3-programmed-filter-checklist.log`).
  The private `3.0-results.local.json` file has not been created; no agent or
  human acceptance result is claimed for this candidate.
