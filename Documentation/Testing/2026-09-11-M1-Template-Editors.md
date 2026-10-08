# M1 template editing and activation admission — 2026-09-11

Implementation commit: `7790497`, following baseline `12d4c61`. This slice adds explicit editing for Headline, Description,
Keywords and photographer Copyright without reinterpreting legacy literal braces.

## Implementation

Headline, Description and Copyright expose Variables… with an isolated editable
draft. Resolve Variables explicitly controls activation. Insert Variable offers
capture date first and appends at the end, as its help states. Invalid activated
syntax disables Apply; Cancel discards the draft. Applying commits the validated
source/version pair, never the sample output. Active source stays intact when
saving a clip or copying/updating a preset. Literal inline edits remain literal.

Keywords use a whole-list draft with one row per entry. Commas, whitespace,
duplicates and order remain exact in stored source; normalization happens only
after expansion. Activation and literal conversion apply to the complete list.
A debounced cancellable worker validates the exact current key before Apply is
enabled; stale or cancelled results cannot commit. Samples are explicitly synthetic
and show unavailable location/person dependencies. No provider or photo is read.

AppStore now admits active saves only with version 3 calendar storage and checks
durable linked-job and pending-receive IDs before persistence, even while the calendar
coordinator is paused. Linked activation explains that newer sharing support or a
detached local copy is required. Job, automation, profile propagation and configuration
imports share this guard. Active imported jobs initialize a missing saved processing
zone on the explicit import boundary; literal imports retain their previous shape.
Direct received-calendar application also rejects activated protocol-2 data.

## Validation

Independent review covered source/version preservation, keyword cancellation and
stale Apply prevention, save/import ordering, linked-calendar rejection and legacy
behavior. Six admission tests and five keyword-draft tests were added.

Full suite: **846 discovered, 831 passed, 15 opt-in skips, zero failures**, exit 0
at 2026-09-11 10:40:52 Europe/Oslo, 41.862 seconds.

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Environment: Xcode 26.6 (17F113), arm64 macOS 27.0 (26A428), development 2.9.2 (37).
Tested dirty state contains this source/test/project slice and its checklist updates.

- Log: `build/m1-template-editors/full-tests.log`
- SHA-256: `5a8062b743947e618bbe608d2ac9e68472cc9dc97648b00d2d0229fc6b14c473`
- xcresult: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.11_10-39-56-+0200.xcresult`

## Native verification

CUA inventory worked. The companion task was inspected using its exact task ID;
its durable report records a host lock during QA, and its later compact snapshot was
idle/interrupted. Its app/settings were left untouched. Existing FTP Sync PID 59841
was preserved. A separate QA app and runner were built in
`build/m1-template-editors/ui-derived`, with app ID
`no.aagedal.FTPSync.TemplateEditorQA` and runner ID ending `.xctrunner`.
Ad-hoc signing disables hardened runtime and is not release-signing evidence.
The UI test binary was newer than the final UI test source. Build-for-testing passed.

Two UI regressions exercise invalid activation, Apply retaining original source,
keyboard cancellation and whole-list cancellation. Native execution stopped with exit 65 before test initialization: the runner
reported “Authentication canceled. Canceled by user.” No test method or app UI flow
ran, and this is not a GUI pass. No authorization bypass or repeated prompt was
attempted. The owned QA app/runner were absent from the final process inventory;
pre-existing PID 59841 remained running. XCTest was a changed observation path,
not a repeat of the previously stalled CUA app selection.

- UI build log: `build/m1-template-editors/ui-build.log`, SHA-256
  `50575317a536de435a4ea54c64e11fd9fd31a722d691d832dd4765da23f26d2d`
- UI execution log: `build/m1-template-editors/ui-tests.log`, SHA-256
  `0f0e3848b9cdeb59220abf93eee8e954eb396ed9516d7b6be76cc8f99e8c590c`
- UI xcresult: `build/m1-template-editors/ui-derived/Logs/Test/Test-AagedalFTPSyncUISmokeTests-2026.09.11_10-43-17-+0200.xcresult`

Retest these methods on an authorized desktop before counting them as evidence.
The checklist catalog parses with 42 unique case IDs and 41 required agent cases;
its existing server/persistence implementation was not changed.

Actual supported-OS behavior, VoiceOver/localization, complete editor layout and
the user's final manual acceptance remain unverified. The checklist instructions now
name the implemented controls; no human or agent manual pass was fabricated.
Candidate identity remains unfrozen and no release gate advances in this checkpoint.
