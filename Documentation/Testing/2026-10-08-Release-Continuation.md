# 3.0 release continuation — 2026-10-08

## Source and environment

Continues `codex/version-3-0-plan` at `9d80096` in the isolated
`t3code/find-version-3-release` worktree. The original checkout and installed app
are unchanged. The installed app is 3.0.0 (42), and its code signature and stapled
notarization validate with macOS trust-service access. Its source commit is unknown.
This source advances to 3.0.0 (43) so the next artifact cannot reuse build 42.

Host: arm64, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a). Three valid signing
identities are visible outside the filesystem sandbox, including Developer ID.
The older zero-identity observations were not a reliable production-signing inventory.
OrbStack was started for a disposable, uniquely named calendar test stack.

The user authorized local TestImages on October 8. Originals are read-only;
the image test uses independent copies, and no private image, library, label,
metadata dump or manifest is committed. The user has no macOS 14 test host.

## Verification completed before archive

| Check | Observed result |
| --- | --- |
| Initial full application suite on 9d80096 plus build-number change | 1,272 executed, 25 skipped, zero failures |
| Disposable PHP/MariaDB calendar suite | 200 PASS assertions; exit 0 |
| Loopback FTP/FTPS/SFTP integration | 16 executed, zero failures |
| Vendored SSH signatures | 2 executed, zero failures |
| Candidate identity rejection tests | 2 passed (dirty/untracked source and app/source mismatches) |
| Checklist persistence/concurrency | 5 passed |
| RAW/XMP verifier contracts | 10 passed |
| Bundled-model reassembly tests | 5 passed |
| Development identity/security guards | Passed for 3.0.0 (43) |
| Bundled model source and signed Debug app | Passed |
| Offline and both Apple OS adapters | Passed public Oslo lookups; synthetic JPEG/XMP round trip retains pixels and caption |
| Opt-in authorized media | 2 tests executed, zero skips/failures; 10 transfer/reprocessing combinations |
| New signed native interruption tests | 2 executed, zero failures |

The authorized media matrix has one Sony ARW, one Canon CR3, one JPEG and two HEIC
samples, each in ordinary and managed folders. It verifies activated photographer/date
Headline delivery, idle repeat polling, read-only preflight, explicit reprocessing,
final engine modification dates, RAW byte integrity or identical decoded pixels,
managed processed-copy integrity and source handoff. Authorized originals and their
canonical source sidecars remain unchanged.

A separate copy of each published output exercises City, Country and Unicode Person
Shown writes. ExifTool independently checks ARW/CR3 outputs in both folder modes:
all 152 ARW and 73 CR3 source-sidecar fields are preserved except approved changes;
the resulting 156/76-field outputs are compared in full; only Headline, Creator,
City, Country and the appended Person Shown name are allowed to change. All four
checks pass and RAW hashes match. This is coverage of these two camera formats,
not every supported RAW family, native Photo Agent display or recognition accuracy.

The bundled real model decodes all five samples: detected-face counts are 0/2/0/2/2.
No names are inferred from this evidence, and it does not count as held-out matching
accuracy. A compatible labeled People Library remains required for that gate.

The native interruption tests click the real reprocessing confirmation, SIGKILL
only the isolated DEBUG app at `beforeCommit`, relaunch, and observe the recovery
warning. They independently read the published JPEG City, modification date and
transaction manifest, byte-match retained originals against the source and prove
that cancellation of the warning keeps backups. The genuine interrupted transaction
is retained for review. These close current-host native reprocessing interruption
observation; they do not prove all job stop/recovery paths, power-loss durability,
manual reconciliation, camera RAW native interruption or macOS 14 behavior.
The hook is compiled out of Release builds.

## Commands and local artifacts

Logs live in `/private/tmp/aftpsync-v3-oct08-*.log`; Xcode result bundles and
retained media outputs live in ignored `build/` directories in this worktree.

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-oct08-tests CODE_SIGNING_ALLOWED=NO
TEST_RUNNER_AAGEDAL_REAL_MEDIA_MANIFEST=/absolute/path/to/manifest.local.json \
  xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-oct08-tests CODE_SIGNING_ALLOWED=NO \
  -only-testing:AagedalFTPSyncTests/AuthorizedMediaAcceptanceTests
swift run --package-path Tools/MetadataCompatibilityProbe MetadataCompatibilityProbe \
  --online-mapkit --online-corelocation
swift test --package-path Vendor/swift-nio-ssh --filter NIOSSHSignatureTests
python3 Scripts/test-build-candidate.py
python3 Scripts/test-3.0-checklist.py
python3 Scripts/test_verify_raw_xmp_integrity.py
python3 Tools/test_prepare_bundled_auraface.py
```

The first real-image invocation skipped because Xcode did not forward the ordinary
environment variable. Only the subsequent `TEST_RUNNER_` invocation counts as a pass.
The first UI compilation found two missing `try` annotations in new assertions;
they were corrected and both native tests passed. The initial transport invocation
had no Python dependencies; the successful run reused the existing pinned benchmark
virtual environment read-only. These failures are not masked as successful runs.

## Candidate workflow and remaining gates

`Scripts/build-3.0-candidate.py` requires committed clean source, validates the
identity/security guards, builds a Developer ID signed Release archive, embeds
`AFTSourceCommit`/`AFTSourceTree` in the signed Info.plist, verifies code signing and
the bundled model, and records the executable hash. `--register` creates a new
manual-checklist candidate ID with status IMPLEMENTING and preserves historical runs.
It never installs, notarizes, pushes or publishes the app.

Still required: full suites after integration, verified signed archive and isolated
Release smoke, Photo Agent schema-3 native exchange and external metadata display,
labeled held-out recognition evaluation, controlled real-provider/model performance,
macOS 14 and other supported-OS/VoiceOver acceptance, remaining native migration/
reconciliation and metadata UI matrix, all final-candidate checklist cases,
independent review and the user-only final acceptance. No missing prerequisite is
counted as passing, and no production release or existing user result was changed.

## Clean-source archive and integrated regression

Developer ID archive from clean `6501476cd415237eed8cd23a1fca8599aadda840`
succeeded. The embedded source tree is
`3075b424333bd055bf544534333dc91bccde3eac`; Info.plist reports 3.0.0 (43)
and minimum macOS 14.0. Strict deep code-signature and bundled-model verification
pass. The archive is Apple silicon; it contains approximately 208 MB of app files.
Executable SHA-256:
`6d96fdc91576f39d0e6a1a3457095162d05740033cae88c60d702dd158e642c9`.
The new candidate is `development-3.0.0-43-6501476cd415-6d96fdc91576`.
It remains IMPLEMENTING; no notarization, installation or publication was performed.

After integration, the complete non-UI suite at this source passes 1,274 executed
tests, 27 opt-in skips, zero failures. The two extra skips are the operator-supplied
image tests, which passed separately with the authorized manifest. The complete
signed UI run is still pending; no final-candidate full-matrix pass is claimed.

## Checklist persistence

The T3 collaborative preview opened the loopback checklist and displayed the exact
3.0.0 (43) candidate, archive path and IMPLEMENTING status. The unavailable macOS 14
case was saved as blocked in the agent lane through the browser, then reloaded;
the durable JSON has revision 1 and zero user entries. Human acceptance is untouched.

This browser activity raised T3 Code in front of the native app during the full
UI suite's managed-image recovery tab click. XCTest explicitly recorded that
interrupting T3 window, and the test could not find the Reprocess control.
The complete run is not counted as passing. Native tests and browser activity
will be serialized for the rerun; no app-code change is justified by this result.

## Independent review and future archive guard

A separate read-only reviewer inspected commit `6501476`, the source/evidence,
media isolation and candidate workflow. No blocking issue was found. The reviewer
identified that the original script could reuse the same version/build after a
source commit changed. The script now rejects any existing artifact for that
version/build and the registered candidate even when its artifact is absent.
All three candidate-script tests pass, and a follow-up review has no findings.
This guard affects future archives; build 43 continues to identify `6501476`.
The review did not independently reproduce tests or close full M0–M6 acceptance.

## Serialized native suite and authorized face evaluation

The complete signed native suite rerun with browser activity paused passes
36/36 tests with zero failures (880 seconds). Log:
`/private/tmp/aftpsync-v3-oct08-serial-ui.log`. The earlier interrupted run remains
a failed observation. This is current-host Debug UI evidence, not macOS 14 or
isolated signed Release acceptance.

The subsequently authorized event folder supplies visually reviewed pseudonym
reference identities and a capture-disjoint held-out matching evaluation.
See [the dedicated report](2026-10-08-Authorized-Face-Evaluation.md). It also
exposed a material compressed-RAW decoder defect; the signed build 43 predates
the diagnostic observation additions and does not contain a decoder correction.
A future source archive needs a new build/candidate identity.
