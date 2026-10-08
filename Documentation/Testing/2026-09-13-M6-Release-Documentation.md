# M6 release-documentation preparation

Date: 2026-09-13

Source revision: `a9acc6ff62118c4dc0bc5785410cdcf9f010e774`

Candidate status: development only; not a beta or release candidate

## Scope

- Replaced the README's obsolete statement that every 3.0 feature is only planned
  with a guarded preview of the behavior present in this branch: explicit metadata
  variables, offline/Apple geocoding, the separate protocol-3 calendar namespace,
  people-library interchange, signed AuraFace component controls and receipt-driven
  safe reprocessing.
- Kept the source/binary boundary explicit. The bundle still identifies as 2.9.2
  (build 37), and the README directs production users to the latest tagged 2.9.x
  release until a 3.0 candidate is published.
- Updated the server guide for implemented protocol-3 create/join and explicit
  classic-calendar migration, and added a concrete additive upgrade/rollback procedure.
  The guide does not claim native/live migration acceptance.
- Replaced three mutable local variables captured by startup-test closures with a
  main-actor test box. This removes the Swift 6 mutation-after-capture warnings without
  changing production startup behavior.

## Verification

- Full macOS app suite on the edited tree: 1,126 passed, 16 opt-in skips, zero failures
  (1,142 discovered). The result bundle contains no build issues.
- `Version3StartupControllerTests`: passed after the concurrency-warning cleanup.
- `MetadataProcessing` package: 33 tests passed with `swift test --disable-sandbox`;
  the flag was required because the enclosing execution environment does not permit
  SwiftPM's nested sandbox.
- `Scripts/check-release-identity.sh`: passed for the unchanged development identity,
  2.9.2 (build 37).
- `Scripts/check-security-baseline.sh`: passed.
- `git diff --check`: passed before commit.

PHP is not installed on this host, so native PHP lint was not run. The existing
disposable PHP/MariaDB integration suite, signed UI execution, screenshots/help,
production distribution notices, 3.0 version/build cut and signed archive remain M6
gates. No installed app, server, model artifact or user data was changed.
