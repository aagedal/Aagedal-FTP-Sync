# M3 namespace-aware calendar sharing

Source `2569206efd2d12c541e952aab04a1625b1d25ad7` on
`codex/version-3-0-plan`, following `93ac5ff`. Reviewed implementation and full
regression suite pass. Existing-calendar conversion, native observation and final
candidate gates remain open.

## Implemented behavior

Version3 local storage now admits template-namespace bindings, cached conflicts and
receive receipts. Legacy stores still reject them. Same account/calendar identity
cannot switch namespace; template snapshots cannot move backwards or change content
at an unchanged revision. Snapshot dates stay canonical at milliseconds; local editor
values may retain finer precision until SharedMetadataDocument constructs wire values.

The coordinator derives bound operations from the saved snapshot namespace, including
polling, publication retries, updates, conflict resolution, invitations and membership.
Explicit discovery selection does not alter existing bindings. Requests retain the
five-argument test transport; a local-only routingProtocol property is excluded from
JSON and selects the actual client's protocol argument. V3 requests include capability
and schema declarations; the client still probes the current endpoint before every
document-bearing v3 request. Coordinator response checks also protect injected
transports against wrong namespace, identity, revision and capability envelopes.
Active-to-literal updates declare exact retained-field conversions against the fetched
remote revision. Literal documents in a v3 calendar never silently switch to protocol2.

Calendar settings now provide **Calendar type / Browse and create**, with **Classic —
compatible with 2.x** and **Template-enabled — requires 3.0**. New publishing and
joining use the selected type; bound jobs display their own type. Classic calendars
stay literal. An unlinked local job can explicitly publish a new template calendar on
an upgraded server. Its persisted revision-zero intent supports retries without
inventing a different UUID. New editor activation on such a link waits for a confirmed
positive server revision. Already-local activated source never goes to an old endpoint
without the v3 capability preflight. No production server was upgraded or contacted.

Copied template invitations carry an explicit readable prefix. A full invitation
selects the template namespace before registration; raw tokens use the user's picker
selection. Legacy copied invitations are unchanged. LF and CRLF are supported. The old
parser rejects the new prefix, while server protocol enforcement remains authoritative.

AppStore admits offline activation on confirmed v3 links and blocks it on legacy or
unconfirmed links. Both protocol directions are checked before applying synced metadata,
so a default legacy call cannot remove activation from an existing v3-bound job.
First incoming activation freezes a missing local processing time zone. Receiving a
copy freezes that same setting before the receipt is persisted. Shared content does not
copy machine provider policy or create new coordinate-sharing consent.

Migration persistence can atomically advance a confirmed journal to a committed rebind,
retaining the original literal baseline and exact creation receipt. Later destination
revisions can advance, but stale saves cannot roll back a cached template snapshot.
The explicit existing-calendar migration/recovery UI and orchestration are still absent;
noncommitted journals keep live sync paused. Committed provenance currently requires
its account and bound destination to remain present, so retained-provenance detach and
account-removal semantics must be implemented before exposing that migration workflow.

## Verification and review

macOS 27.0 (26A428), arm64; Xcode 26.6 (17F113). Debug app version 2.9.2 (37),
unsigned test configuration, at
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Build/Products/Debug/AagedalFTPSync.app`.
Tests used temporary folders, synthetic calendars and injected credentials/transports.
One test wraps the actual Swift wire client to verify capability refusal sends no
create document. No user calendar, production endpoint, photo or credential was used.

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Final run: exit 0, **998 discovered, 983 passed, 15 opt-in skips, zero failures**,
50.767 seconds; completed 2026-09-11 20:29:58 +0200. All final app/test changes were
present as owned dirty changes and then committed unchanged at `2569206`.
Log `build/m3-namespace-routing/full-tests.log`, SHA-256
`2a471fd33f361ef35e2fd8a63bc4bb072dbc2da99041679d998eb916f1a02831`.
xcresult: `Test-AagedalFTPSync-2026.09.11_20-29-01-+0200.xcresult` in the same
DerivedData root's `Logs/Test/` directory.

There are 17 additional test groups since the prior complete source set: eight
namespace-storage, six coordinator and three activation-admission cases. Existing
invitation tests gained prefix/line-ending coverage. Earlier provisional storage gate
tests were updated to require namespace-safe admission and atomic journal rebind,
while retaining old-store/downgrade rejection checks.

The first integrated run exited 65 with two legacy conflict-review regressions: the new
binding gate rejected cached changed-scope/older-revision conflicts before the existing
review could show its safe, actionable refusal. Root retained that legacy review behavior
while keeping strict v3 conflict checks; no local state or remote write was permitted by
those cases. Initial log hash:
`da11bf922fd02746ff9d3e7d0d586ae3378d33a081126ac1f4a004c22715ee50`.
The intermediate full run passed, then review found legitimate local submillisecond dates
needed acceptance before the wire boundary. Added a regression and fixed the distinction;
final run above includes it. Intermediate log hash:
`dd927ffe6c6308ce280e1463e8bab44486dc06a38b11afa157dc0556e2e75ad7`.

Independent agents implemented storage/routing and coordinator tests. Independent review
of root's activation/UI found the asymmetric default-legacy apply boundary; root fixed
it and added preservation assertions. Storage review added stale revision/content guards.
Root integrated and ran all builds serially. Diff checks passed. These are automated
regressions, not native GUI, live server, oldest-OS or release-signing evidence.

Desktop inventory succeeded in 0.2072 seconds; Photo Agent was not running and no FTP
app was listed. The companion task reported active status with an interrupted latest
turn and prior desktop-work commentary. No simultaneous app operation or unchanged
native-selection retry was attempted. Existing native observation/authentication issues
remain unresolved; no new UI control was observed and no manual case was passed.
The checklist now includes exact picker, publish/join and invitation instructions and
states that full existing-calendar migration acceptance remains unavailable. Local human
results remain absent/untouched. The development identity changed; older result sets
are preserved. App version and installed stable copy are unchanged.

## Next work

1. Implement the explicit existing-calendar migration workflow with unsynced-edit review,
   fresh capability verification, prepared intent before sending, same-UUID recovery after
   uncertainty, confirmed snapshot persistence and atomic rebind. Add safe retained
   provenance for later detach/account removal and interruption/relaunch tests.
2. Observe new sharing controls, activation, conflict and receive-copy behavior on an
   authorized desktop with disposable HTTPS servers, including actual old-client paths.
3. Continue M4 model/library/recognition and M5 provenance/performance; retain supported-OS,
   real-model and final candidate gates. No deployment, push or release is authorized.

Substantive progress continued; blocked-cycle count remains zero.
