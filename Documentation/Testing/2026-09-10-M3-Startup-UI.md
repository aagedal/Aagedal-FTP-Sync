# M3 production startup and source selection — 2026-09-10

Implementation commit: `1bd6c1f`. This is a development checkpoint, not a release
candidate or an observed manual-test pass.

## Implemented behavior

Production menu, Settings and data windows now wait for a single startup controller.
No normal AppStore is constructed while inspection, source selection or recovery is
pending. The independent Startup and Recovery window provides explicit choices for
all nine JSON libraries and signatures, plus separate open and prepared-copy recovery
actions. A sole backup is not selected implicitly. Damaged committed storage never
falls through to fresh state. Inventory is read-only and bounded; selected content
is validated by migration. Recovery details expose stages and filenames, not decoded
payloads or credentials.

Admission requires confirmation that other copies are closed and checks same-bundle
processes before and after asynchronous bootstrap. A newly observed copy permanently
blocks new work, requests cancellation of active operations and requires relaunch.
The runtime and lease stay owned. Detection and acknowledgement are user-mediated
exclusion, not a race-free barrier against an uncooperative 2.9 writer; cancellation
is not proof of completed draining. Saved launch preferences remain intact, but every
admitted session currently starts paused and requires explicit calendar activation.
Automatic restoration of selected jobs on later launches remains a product-policy gap.

Test launch isolation runs before production paths. An explicit isolated v3 startup
mode uses only the test session root, fake credentials and transport. Production
Application Support parent creation and the final admission/publication conflict race
were corrected during independent review. Queued metadata reset work also checks the
permanent suspension flag before starting.

## Automated validation

Final unchanged-source full suite: **732 discovered, 717 passed, 15 opt-in skips,
zero failures**, exit 0 at 2026-09-10 15:49:43 Europe/Oslo; 34.294 seconds.
This includes eight source-catalog and eleven startup-controller tests. The earlier
731-case run preceded final review corrections and is not the final-source result.

Command:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Environment: Xcode 26.6 (17F113), arm64 macOS 27.0 (26A428). Development app remains
2.9.2 (37); installed stable copy was not replaced.

- Log: `build/m3-startup-ui/full-tests.log`
- SHA-256: `d958f974f63759a6d7c3df9622319f590f8130570170ce67a5873fd82b163601`
- Result bundle: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.10_15-49-03-+0200.xcresult`

## Computer testing attempt — incomplete

Surface inventory worked, and another coordinator reported resumed native access.
A changed launch method used LaunchServices with isolated v3 test-session environment
variables. Its owned process 82934 was terminated before a separate disposable QA copy
was launched. The copy uses bundle identifier `no.aagedal.FTPSync.StartupQA` and an ad-hoc
signature; its compiled source matches the tested code, but it is not distribution
signing evidence. Session: `coordinator-startup-qa-20260910`.

Selecting `build/m3-startup-ui/FTP Sync Startup QA.app` through the computer tool
returned `-10005: timeoutReached` after **722.8949 seconds**, despite a requested
20-second timeout. No native UI state, screenshot, selection or recovery interaction
was observed. Launch success does not establish GUI correctness. No checklist case
was marked passed. The owned QA process 82999 was terminated and subsequently verified
absent. Pre-existing process 59841 was left untouched.

QA executable SHA-256:
`e7d63ff972452c34b6d7708d6dad9148c0e73cba20895f217169d3e86a5832be`.
The checklist's m3-001 instructions now describe actual startup controls, while its
status remains unrun. Human results remain absent. Actual startup/recovery observation,
continuous older-writer constraints, activated workflows and all candidate gates remain
open. Do not repeat the same blind native-selection attempt without new evidence.
