# M3 explicit classic-calendar migration

Implemented at `2ee1c2895184fc7229e20b3f6ef9a6286fa4bb6f` on
`codex/version-3-0-plan`, following `2e8f541`. Full regression suite and independent
review pass. Native/live-server acceptance and the other 3.0 milestones remain open.

## Behavior

A classic owner calendar offers **Create Template-Enabled Calendar…**. Preparation
requires version3 local storage, an unrestricted/conflict-free owner baseline, no
pending receive, no open draft and no unsynced local document changes. It checks
fresh authenticated protocol3 capabilities and fetches the exact current classic
snapshot before presenting a review. That review names the captured local job,
source revision and server; Cancel has no persisted migration or remote create effect.

**Create and Link New Calendar** checks the source again, including a fresh classic
GET after the review delay. It persists one prepared UUID before sending any create
document. Fresh capability verification precedes creation; the ordinary wire client
also retains its per-document capability probe. Exact owner/schema3/revision1/source
confirmation is saved before the binding and committed receipt are replaced atomically.
The job's metadata stays literal and unchanged. Neither the old server calendar nor
its memberships/invitations are mutated or copied. New participants need fresh invites.

The fork is fixed at the explicitly reviewed, durably recorded source revision. Other
classic participants can continue editing the old calendar afterward; those later edits
are preserved there and are deliberately not merged into the new fork during recovery.
Local job, binding, draft and endpoint changes are different: they stop creation or
rebind so local edits cannot silently move to a different reviewed calendar. Checks run
again after capability suspension and immediately before create. An in-flight create
can still return an exact confirmation; it is retained before the local rebind check.

**Retry Migration / Finish Calendar Migration** uses the saved UUID. A prepared retry
first fetches that destination. Only the specific authenticated calendar access-denied
code permits retrying the same idempotent create; it is not proof of absence, and server
ownership/collision checks still apply. Authentication, capability and unrelated errors
never take that branch. Scoped migration requests can bypass the ordinary pending gate
only for the exact durable journal, source, account, endpoint and protocol3 capability/
get-destination/create-baseline action, checked before and after transport. Normal polling
does not initiate or resume a migration automatically. Pending states remain visible
after restart and preserve the original binding until the atomic rebind succeeds.

**Keep Using Classic Calendar…** provides an escape when local edits or uncertainty
prevent completion. Its confirmation names the original job/calendar/server and explains
that any new server calendar remains there. It retains the current classic binding and
local edits, archives the original intent/optional server receipt, and performs no
network operation or remote deletion. Committed migrations use the existing **Detach
and Keep Local Metadata** action, atomically archiving provenance with binding removal.
Detached/abandoned records are terminal and remain durable. They permit later account
removal and receipt into a new local job, while rejecting stale restoration of the old
destination into the original job. Archives do not block later independent processing
or a new migration with a fresh UUID.

## Validation

macOS 27.0 (26A428), arm64; Xcode 26.6 (17F113). Debug 2.9.2 (37), unsigned test
configuration; app path:
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Build/Products/Debug/AagedalFTPSync.app`.
Temporary stores, synthetic literal calendars, injected endpoints/keys and controlled
save/transport faults only. No user calendars, production network endpoints or photos
were used; the installed stable app was not replaced.

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Final run: exit 0, **1,015 discovered, 1,000 passed, 15 opt-in skips, zero failures**,
58.414 seconds; completed 2026-09-11 20:53:24 +0200. Final owned dirty source and tests
were committed unchanged at `2ee1c28` afterward. Log
`build/m3-calendar-migration/full-tests.log`, SHA-256
`2beb9c10a02291097cf322da6af645bdef5c1f9b466b847cfff3767986ac4308`.
xcresult: `Test-AagedalFTPSync-2026.09.11_20-52-20-+0200.xcresult`, in the same
DerivedData root's `Logs/Test/` directory.

Seventeen new test groups: eleven coordinator cases and six archive cases. Evidence
covers a separate read-only review, saved intent before create bytes, exact rebind and
unchanged classic content, lost-response restart without duplicate creation, failures
before each of the three saves, same-UUID create retry after a pre-commit network failure,
unrelated authentication/capability refusal, local/draft/stale-disk/remote-review changes,
no-network abandonment, atomic archive transitions, stale-resurrection rejection and
new-job rejoining. A remote classic revision advancing after the durable fork is tested
separately from a change during the initial review.

The initial full run also passed (1,012 discovered, 15 skips, no failures); after adding
three recovery regressions and clearer UI job/server context, the final full run above
was executed. Initial log SHA-256:
`b9456628fc839412870401bfacc9e16f69bc2abf7b32ea25e086dc93c2a9a444`.
No failed build/test run occurred in this slice. Diff checks passed.

Independent agents implemented coordinator/archive changes and tests. Independent
reviews covered scoped migration authorization, atomic monotonic receipts and UI
selection changes. Review identified missing original server/job context in global
recovery controls; root added explicit labels and abandonment context. Root also
required a fresh pre-create local/draft check after capability suspension and a safe
no-delete abandonment path. All Xcode builds were serialized by root.

The companion task still reported active status with an interrupted latest turn and
unchanged earlier desktop-work commentary. No unchanged native-selection retry or
simultaneous app operation was attempted. No new native controls, actual server migration,
supported-OS behavior or signed UI run is claimed. The previous desktop selection and
XCTest authentication limitations remain open. Existing Swift-wire/PHP namespace tests
remain evidence for unchanged components, not an end-to-end native migration pass.

The 42-case checklist now includes exact review, confirmation, interruption/retry,
abandonment and detach/rejoin instructions. It explicitly requires a disposable delayed
or discarded response fixture for interruption acceptance. Concrete native/live fixture
setup and observed evidence are still required before handoff. User results remain
absent and untouched; no manual agent case was advanced. A new development identity
preserves all earlier result-set identities. No release, push, production deployment,
notarization or purchase occurred.

## Next work

1. Verify the full sharing/migration UI and crash/relaunch paths on an authorized desktop
   with disposable HTTPS servers and controlled response interruption. Inspect actionable
   error messages for legacy-storage/old-server refusal. Keep classic calendars separate.
2. Begin M4 model/library installation and recognition integration against the pinned
   companion exporter contract. Coordinate companion source ownership and required
   actual-image/supported-OS evidence rather than treating fixture acceptance as integration.
3. Finish M5 fingerprints, stale/incomplete reprocessing and measured burst budgets;
   retain native, supported-OS, real-model, signing and final user acceptance gates.

Substantive implementation continued; blocked-cycle count remains zero.
