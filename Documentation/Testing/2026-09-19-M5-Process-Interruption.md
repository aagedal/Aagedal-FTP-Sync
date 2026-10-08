# M5 metadata publication process interruption — 2026-09-19

Source: clean `0ae65f0` application base plus the tests, harness and documentation
committed with this report on `codex/version-3-0-plan`. No application code or
candidate identity changes. Host: arm64 MacBook Pro, macOS 27.0 (`26A428`),
Xcode 27.0 (`27A266a`). App remains 2.9.2 (37). No private checklist results
file was present; no user results or acceptance entries were changed.

## Coverage

The opt-in worker invokes `LocalEndpointSession.importFilesTransactionallyMatching`
with a nested synthetic RAW primary and existing XMP companion. Its phase hook
writes an exact marker and sends SIGKILL to its own test host, bypassing rollback,
catch blocks and normal cleanup. The harness requires both an expected Xcode exit
65 and an xcresult failure identifying SIGKILL (`Test crashed with signal kill.`).
An ordinary exit, setup failure or missing phase marker cannot count as success.

A separate fresh test host reads the actual retained manifest and checks:

| Interruption | Expected retained state |
| --- | --- |
| Prepared | Original paths intact; inspected snapshots and manifest present |
| Originals held | Both original paths absent; both originals retained byte-for-byte |
| XMP published | Published XMP present; original RAW and XMP still held |
| Before commit | Same partial state before guard-only RAW restoration |

Every recovery case verifies path mapping, guard-only RAW identification, original
snapshot/held bytes, expected path presence, and admission rejection identifying
the recovery directory. It follows the documented reconciliation choice: retain
published XMP when present, restore missing originals, then remove the resolved
recovery directory. Admission reopens and a fresh byte-matched publication succeeds,
with unchanged RAW bytes, the new XMP and no remaining recovery folder. A completion
marker plus Xcode success prevents a skipped verification from passing the harness.

## Commands and results

```sh
xcodebuild build-for-testing -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -derivedDataPath build/v3-preview-consistency CODE_SIGNING_ALLOWED=NO
python3 Scripts/test-metadata-process-interruption.py \
  build/v3-preview-consistency/Build/Products/AagedalFTPSync_macosx27.0-arm64.xctestrun
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests CODE_SIGNING_ALLOWED=NO
python3 -m py_compile Scripts/test-metadata-process-interruption.py
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

Final harness: all four worker/recovery pairs pass (harness exit 0). Worker exit 65
is intentional and required; every fresh recovery process exits 0.

Final harness evidence: `build/aagedal-interruption-ubc5wryj/`, including per-phase
worker/recovery logs and xcresult bundles plus `results.json`. Console log:
`build/v3-interruption-verified.log`. Final build log:
`build/v3-interruption-build-final.log`.

Focused publication regression: 18 executed, 15 passed, three opt-in skips,
zero failures (exit 0), in `build/v3-interruption-focused.log`. The three skips are
the large-directory benchmark and the two externally configured interruption tests.
The final signal-delivery correction was subsequently rebuilt and exercised by the
opt-in harness. Python syntax, security/identity guards and diff validation pass.
Xcode required approved compiler/package-cache access.

Earlier harness development exposed a race between SIGKILL delivery and a fallback
`_exit(99)`. The worker now waits for signal delivery after a successful kill syscall;
xcresult inspection rejects ordinary exits. Those earlier exit-based runs are not
SIGKILL evidence. The final harness also recognizes Xcode's textual `signal kill`
spelling rather than requiring the numeric spelling.

## Limits and next steps

This provides controlled process-termination evidence for the local publication
primitive, not an end-to-end native job interruption or power-loss durability.
Fixtures are synthetic byte payloads, not decoded camera RAW/XMP metadata. The
manifest is still a path map, not an automatic replay journal. Reconciliation here
is performed by the verification code, not by the user in the native UI. The final
candidate, native recovery errors, managed-folder UI, supported-OS matrix, actual
metadata interoperability and real-model performance/accuracy remain open. No
milestone or required checklist case is closed by this report. Other project tasks
were active; no shared-desktop automation was used.
