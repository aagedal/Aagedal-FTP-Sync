# Scoped image recovery and reviewed conflicts — 2026-09-21

Source: clean `47df8140b1af0375f0bd5c087a18706864da6481` plus the test changes
committed with this report, on `codex/version-3-0-plan`. Host: arm64 macOS 27.0
(`26A428`), Xcode 27.0 (`27A266a`). Development identity: 3.0.0 (38).
No private results JSON was present; historical candidate and checklist lanes
remain unchanged.

## Verified behavior

The new integration regression runs eight combinations: ordinary or managed
`Synced Files`, photographer or clip scope, and retained publication transaction
or reset recovery folder. Each starts with a real transfer of a generated,
decodable JPEG, an opaque synthetic RAW primary with a generated valid XMP
sidecar, and an image belonging to a different photographer. Files are nested.

After editing the RAW sidecar, no-write preflight finds one ready JPEG and one
reviewed conflict. A recovery folder introduced after that review blocks both
fresh preflight and previously approved publication. All visible image/sidecar
bytes, retained original bytes and persisted audit entries remain unchanged.

Explicit fixture reconciliation moves the retained backup outside the watched
folder. A new engine and reopened repositories then reproduce the same review,
publish both selected outputs with the resolved photographer variable, preserve
the RAW bytes and excluded photographer's image, and retain the reconciled
backup. Persisted completion receipts survive another engine/repository reopen;
a stale/incomplete repeat skips both images without changing bytes.

The first run exposed a test fixture mistake: the edit used the embedded-image
writer overload instead of the RAW-sidecar overload. Correcting the fixture's
`relativePath` argument produced a passing run. No production code changed.

## Verification

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/MetadataProgrammingCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

Focused new test: one passed, all eight combinations, exit 0 (1.505 s).
Surrounding regression selection: 106 executed, 101 passed, five opt-in skips,
zero failures, exit 0 (7.381 s). Security, development identity and diff checks
pass. The initial restricted build could not access SwiftPM/Clang caches;
approved Xcode invocations completed successfully.

Logs: `build/v3-scoped-image-recovery-initial.log` (fixture failure),
`build/v3-scoped-image-recovery.log` (corrected test), and
`build/v3-scoped-image-recovery-focused.log` (surrounding selection).
Result bundles under `build/v3-preview-consistency/Logs/Test/`:

- `Test-AagedalFTPSync-2026.09.21_11-40-50-+0200.xcresult`
- `Test-AagedalFTPSync-2026.09.21_11-41-14-+0200.xcresult`

Unsigned app: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.
App-code debug dylib SHA-256:
`39b3d591207fb7c8787744f40d231911ee87cf392a6ebbda62a4345d8a633b16`.

## Remaining scope

Other projects had active tasks on the shared desktop; this run used isolated
non-UI fixtures. Engine/repository reopening is not an app relaunch observation.
Camera RAW decoding, native scoped image/conflict recovery, external-reader
integrity, VoiceOver and macOS 14 remain open. No whole milestone or candidate
acceptance is claimed. Next, carry this image batch into the existing isolated
native editor recovery workflow and observe review, reconciliation and publication.
