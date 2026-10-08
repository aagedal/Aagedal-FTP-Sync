# Selected-source migration and recovery checkpoint

App-code commit: `67d91fa`. Independently reviewed source, then full coordinator
validation. No app source changes after the passing run; documentation follows.

The explicit migration driver connects selected primary/backup sources, frozen-calendar
JSON conversion, original-byte-safe SQLite acquisition, all legacy name maps and the
initial registry. An immutable selection record and initial manifest retain provenance.
Strict complete-family current validation preserves original envelope/database bytes;
committed opens use the locked current registry. PREPARED recovery uses frozen output,
never recopies edited legacy inputs, and rejects WAL/journal companions before validation.
Acquisition receipts cannot be forged independently from the raw capture. Unknown files,
omitted mappings, ambiguous absent choices and incompatible current stores fail closed.

Independent review identified and resolved two gaps before the full run: empty older
calendars remain admissible without invented tracks, and initial/PREPARED SQLite output
must reject omitted companions as well as ordinary committed reads. Integration tests
cover selected damaged-primary/valid-backup retention, WAL-only committed rows, immutable
selection, runtime mapping admission/loss, both recovery locations and changed legacy data.

## Validation

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Exit 0, completed 2026-09-10 14:32:57 Europe/Oslo: **685 discovered, 670 passed,
15 opt-in skips, zero failures**, 25.273 seconds. All 27 added tests pass.
Isolated signature/snapshot validation also passed 46 tests before integration.
`git diff --check` passed. Host: arm64 macOS 27.0 (26A428), Xcode 26.6 (17F113).
Development app remains 2.9.2 (37), installed app unchanged.

- Full log: `build/m3-selected-migration/full-tests.log`
- SHA-256: `9156005c61559722cfbaa1bbd2badbb46d1110a6fc880e9d7d86d8b13a6062d1`
- Result: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.10_14-32-19-+0200.xcresult`
- Built app: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Build/Products/Debug/AagedalFTPSync.app`

## Remaining gates

This driver is opt-in infrastructure. Production App.main still uses legacy startup.
The caller must exclude all writers, including older app processes, throughout each
migration/open/recovery call; lifetime exclusion is not yet wired. Bootstrap must expose
loading/ready/recovery and explicit source selection before any app/calendar constructors,
then inject the same admitted layout and preserve launch/pending-receive policy. Transfer
sessions still need registry provisioning. Admission disables obsolete credential garbage
collection to preserve references in retained archives, including undecodable backups.

No actual app UI, supported-OS, online transport, signed candidate or release evidence
is claimed. No candidate or checklist gate advanced; human results remain untouched.
Continue startup integration before user-facing activation and final UI validation.
