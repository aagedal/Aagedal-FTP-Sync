# Runtime mapping admission and paused calendar checkpoint

App-code commit: `14e2e1f`. All three slices received independent source/test review.
The coordinator alone regenerated the project, ran Xcode and committed the changes.

Runtime download naming now admits or provisions the exact normal/replacement map
through the v3 registry before constructing transfer/source sessions. Both transfer
directions and source-modification reprocessing propagate refusal. Preexisting PREPARED
registry records require explicit recovery; committed missing maps remain missing and
block publication. Legacy mapping behavior is unchanged.

The strict calendar factory reloads the admitted v3 calendar and diagnostic history
before construction, preserving pending receive data without replay, network, credentials,
observation or polling. Explicit start activates it. Strict stop re-arms the pause gate;
reactivation waits while an earlier operation is busy so a late response cannot apply.
This is not a complete shutdown/drain barrier for app jobs or all repositories.

The cooperative lifetime lease uses persistent `.v3-runtime.lock`, nonblocking flock,
no-follow ancestor traversal, regular/single-link file checks and descriptor/path identity
validation. Object destruction releases descriptors without unlinking the lock. It does
not exclude older versions or nonparticipating writers. Production startup does not yet
acquire it or select v3 storage.

## Verification

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Final run exit 0, 2026-09-10 14:54:28 Europe/Oslo: **700 discovered, 685 passed,
15 opt-in skips, zero failures**, 31.318 seconds. Fifteen new tests cover six lease
lifecycle/path groups, seven paused calendar groups and two runtime naming groups
(including four direction/mode combinations plus reprocessing admission failures).
`git diff --check` passes. No source changes followed this passing run.

The first full run failed only the two new naming tests during migration fixture setup
with `unsafePath`; it had not reached runtime mapping assertions. Replaced Foundation's
temporary-root-based fixture with a separate explicit physical `/private/tmp` fixture,
matching existing driver tests, then reran the entire suite. Independent review approved
the correction. The exact rejected path component was not logged; production bootstrap
must establish trusted physical paths rather than assume alias resolution is sufficient.

- Full log: `build/m3-runtime-admission/full-tests.log`
- SHA-256: `c30d3c80287097ecfbfb1d1bfa18aca565df8db6353c36c0385f86fd00f9a0e4`
- Earlier failure: `build/m3-runtime-admission/initial-fixture-failure.log`
- Result: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.10_14-53-53-+0200.xcresult`
- Built app: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Build/Products/Debug/AagedalFTPSync.app`
- Host: arm64 macOS 27.0 (26A428), Xcode 26.6 (17F113). Development 2.9.2 (37).

## Next integration boundary

Move eager AppStore/calendar construction behind one loading/ready/recovery owner.
Establish physical roots and older-writer exclusion, retain the cooperative lease,
perform explicit migration/recovery admission, then construct both paused factories
from the same layout and publish them together. Loading/error scenes must not instantiate
default repositories. Retain the lease for the full process lifetime; stopAll is neither
a write-drain barrier nor restoration of saved per-job launch preferences. Keep initial
migration paused for user review and protect retained credentials through disabled
obsolete-credential collection.

No new GUI evidence: these paths are not exposed by production startup, and the prior
native computer-selection stall remains unresolved. Other app coordinators are active;
no desktop was claimed this cycle. Installed copy, human results, candidate identity and
all required unpassed gates remain unchanged. No release readiness is claimed.
