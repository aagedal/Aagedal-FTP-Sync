# Photo Agent default recognition policy — 2026-09-21

User instruction: implement Photo Agent's default settings, preferring missing
names over false assignments. This explicitly replaces the earlier decision to
leave the production policy unconfigured. It does not establish a measured
false-positive rate or waive real-photo verification.

Base FTP Sync source: `803d2e7` plus this change; branch
`codex/version-3-0-plan`. Companion defaults inspected at
`ace5f8b1037fbab6d6067d8b0163d8ff93e46e85`, clean working tree:
`Models/FaceRecognitionDefaults.swift` and `Services/KnownPeopleService.swift`.
Host: Apple silicon, macOS 27.0, Xcode 27.0. App identity: 3.0.0 (38).

## Implementation

The existing enabled bundle flag had no threshold values, so production policy
loading failed closed. Supply all three required values in Info.plist:

- Maximum cosine distance: 0.68, equivalent to the nominal 0.32 minimum similarity.
  FTP Sync preserves its strict distance comparison (distance must be below 0.68).
- Minimum gap between best and second-best person: 0.04.
- Minimum capture quality: 0.15. Missing quality remains rejected.

The existing runtime already uses single-pass landmarks detection, confidence
at least 0.70 and minimum original face width 50 pixels. No detector change is
needed. Full-gallery ambiguity evaluation remains stricter than Photo Agent's
threshold-filtered candidate list, including a runner-up outside the match cutoff.
No grouping/clustering threshold is used for name publication.

Startup still validates the bundled model and compatible selected library. Jobs
still require explicit recognition enablement; importing a library does not
start jobs. Relaunch after selecting/importing the library to admit its snapshot.
The settings status now describes model/library validation instead of requesting
unavailable calibrated settings. README and readiness document the actual policy.

## Verification

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/FaceRecognitionMatcherTests \
  -only-testing:AagedalFTPSyncTests/AuraFaceComponentInstallerTests \
  -only-testing:AagedalFTPSyncTests/AuraFaceRecognitionRuntimeTests \
  -only-testing:AagedalFTPSyncTests/Version3BootstrapCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/FaceRecognitionAnalysisServiceTests \
  -only-testing:AagedalFTPSyncTests/MetadataFaceNameWriterTests \
  CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
plutil -lint AagedalFTPSync/Resources/Info.plist
python3 Tools/verify_bundled_auraface.py app \
  'build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app'
git diff --check
```

69 tests executed: 68 passed, one opt-in reference test skipped, zero failures;
exit 0. Real bundled-model admission passes. The new regression reads the actual
host application's bundle policy and verifies clear acceptance, weak rejection,
ambiguity despite an outside-cutoff runner-up, quality boundary and missing
quality. Existing missing/invalid configuration checks still pass. Security,
development-identity, plist, compiled-model/license and diff checks pass.

Log: `build/v3-photo-agent-defaults.log`.
Result: `build/v3-preview-consistency/Logs/Test/Test-AagedalFTPSync-2026.09.21_19-05-12-+0200.xcresult`.

No private photos/library were opened or modified, and no jobs were enabled in
the user's installation. No native photo workflow, held-out face accuracy, or
signed release-candidate result is claimed. Historical candidate/checklist state
remains unchanged; the next candidate needs a new identity.
