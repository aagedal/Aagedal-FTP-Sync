# M5 reprocessing recovery admission — 2026-09-19

Development source: clean base `02a8dd1` plus the implementation, tests and records
committed with this report on `codex/version-3-0-plan`. Host: arm64 macOS 27.0
(`26A428`), Xcode 27.0 (`27A266a`). App identity remains 2.9.2 (37).
No private results JSON was present. The earlier candidate identity is unchanged.

## Change and reproduction

Reprocessing previously excluded hidden recovery directories from its file listing
but still allowed a fresh preflight and writes. A retained original could therefore
be absent from the reviewed batch while visible outputs received another revision.
The new regression failed on the preceding implementation and observed an actual
JPEG changing from 703 to 3,320 bytes despite retained recovery state.

Reprocessing now requires recovery reconciliation before listing destinations or
opening sources. Snapshot validation and byte-matched publication recheck the
boundary, including recovery appearing after admission. Both managed `Synced Files`
and ordinary destinations reject retained `.transaction` and reset `.trash` names.
This does not depend on a readable manifest. Reset and reprocessing share the name
predicate. The error includes the recovery path; backups and current images remain
untouched, and explicit retry works after recovery is resolved.

## Verification

All 94 selected tests pass, zero failures/skips, exit 0: 29 activated integration,
11 matching-publication and 54 local-sync integration tests. Disposable regressions
cover both destination modes, both recovery types, preflight/write rejection,
byte preservation, later recovery appearance, manifest-free holdings and retry.
An initial test-only URL assertion needed canonicalization for macOS `/var` versus
`/private/var`; the final run passes with resolved paths.

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  -only-testing:AagedalFTPSyncTests/LocalSyncIntegrationTests \
  CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

All guards pass. Xcode required approved compiler/package-cache access after the
sandbox denied manifest cache writes. Logs: `build/v3-recovery-admission-before.log`
and `build/v3-recovery-admission.log`. Final result:
`build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.19_21-17-40-+0200.xcresult`.
Test app: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`.

## Remaining acceptance

Native UI and actual process-termination recovery remain unverified. Another project
task was active on the shared desktop; this run used isolated non-UI fixtures.
The guard checks directory state at admission/publication boundaries; it is not
cross-process filesystem isolation or automatic recovery. Large-folder reprocessing
performance needs measurement because each snapshot/publication recheck reads the
root's child names. Ordinary synchronization behavior is unchanged. Camera RAW,
real-face calibration, supported-OS and signed candidate gates remain open. No
milestone or checklist acceptance was marked complete.
