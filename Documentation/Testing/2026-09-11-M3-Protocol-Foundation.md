# Protocol 3 namespace and wire foundations

Source: `778c61b` on `codex/version-3-0-plan`, following `7fa8bb3`.
Reviewed foundation; production calendar activation remains guarded. No deployment,
new shared calendar, or candidate readiness is implied.

## Implemented

The PHP endpoint routes protocol 2 to unchanged legacy tables and protocol 3 to
separate calendar, membership and invitation tables. Device authentication is shared;
calendar data never falls back between namespaces. Additive `schema-template-sync.sql`
must precede upgraded PHP: both protocol paths inspect the new tables. Failure to
install the SQL first fails safely but interrupts legacy sync. Nothing was deployed.

Authenticated capability discovery reads no document. Every v3 request repeats
`metadata-templates-v1`; every v3 envelope declares it. Document-bearing v3 requests
require schema 3. Snapshots and summaries retain immutable schema/minimum-protocol/
capability headers even if all text becomes literal. Valid activation markers and
bounded token syntax are preserved verbatim. Retained fields losing activation require
an exact explicit deactivation list against the locked current revision; missing,
duplicate or extra transitions fail. Range reconstruction preserves hidden records.

Membership or invitation authorization precedes resource capability gates, and gates
precede snapshots, revision conflicts, redemption and mutation. Incompatible clients
receive no source payload. V2 lists omit v3 records. Both creation paths lock the same
bootstrap row before checking the other namespace, preventing different owners from
creating the same UUID in separate tables. Re-upgrade collisions are quarantined.
Actual old PHP cannot see v3 tables; an old literal write targets only its old identity.

Swift adds strict compatibility headers and typed deactivation diff validation while
preserving absent-header legacy bytes. Recursive store preflight detects later v3
headers even if earlier data is malformed, blocking backup recovery/stale saves that
would erase new semantics. The production legacy cache gate deliberately still rejects
v3 snapshots: persisted namespace bindings and migration are the next slice.

The explicit v3 client route probes the current authenticated endpoint immediately
before every document send, with no cached grant, redirect, cookie or namespace fallback.
It validates envelope capability/version before domain decoding, requires exact v3
snapshot headers, preserves active source in valid conflict replies and exposes only
safe upgrade errors. Existing coordinator calls still default to protocol 2.

## Independent review

Agents reviewed model/codec compatibility, client preflight, PHP namespace/authentication
ordering, parser parity, range/deactivation behavior and concurrent creation tests.
Review moved resource checks after authorization while retaining their position before
payload/conflict responses. No remaining actionable blocker was found in this slice.

## Swift validation

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

**964 discovered, 949 passed, 15 opt-in skips, zero failures**, exit 0, completed
2026-09-11 19:31:11 +0200 in 46.214 seconds. Fifteen tests added. Environment: arm64
macOS 27.0 (26A428), Xcode 26.6 (17F113). App remains 2.9.2 (37); installed stable copy
unchanged. Swift source was unchanged between the final run and source commit.

The first run failed in four client test methods because their active fixture used
unsupported `{date:YYYY}`. It was corrected to supported `{date:YYYY-MM-DD}`; the
unsupported-looking literal fixture stayed literal. Rejection assertions were also
strengthened to require `unsupportedProtocol`, preventing a fixture error from counting
as an expected refusal. No production parsing rule was relaxed.

- Passing log: `build/m3-protocol-foundation/full-tests.log`, SHA-256
  `d9046d73ee20556147923c3a36c6e1fb02594ad83cc122472df037ae96a8cfd8`.
- Initial failure log: `build/m3-protocol-foundation/initial-test-failure.log`, SHA-256
  `4f584bea1cd940ae9d752c66116e8738e8186c6f4166d023529e4ebc53f18530`.
- xcresult: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.11_19-30-22-+0200.xcresult`.

## PHP/MySQL validation

Started the installed OrbStack runtime through its CLI because the Docker socket was
absent. Used a uniquely named disposable compose project, tmpfs database, internal-only
network and dummy test credentials. No host port or production endpoint was used.

```sh
docker compose -p aftpsync-protocol3-20260911 \
  -f Server/MetadataSync/tests/compose.yaml up --build \
  --abort-on-container-exit --exit-code-from test
```

Exit 0. Hosting checks, existing live-sync regressions, template namespace checks and
all eight concurrent creation races passed. Two different owners reached the shared DB
lock concurrently in each race before the barrier released them; exactly one namespace
won, the loser received no document, and no cross-table collision was created. The
rollback server executes exact `a9a5a14` PHP fixtures against the migrated disposable DB;
old list/read/stale-write/invite paths cannot see v3, and an old cached literal write
leaves v3 source and revision unchanged. A simulated rollback UUID collision is
quarantined on re-upgrade without mutation. The first run passed before adding the
concurrent race; the final run includes it. Containers/network were removed afterward.

PHP 8.3.33 / Zend 4.3.33, MariaDB 11.4.13, Docker 29.4.0. Image identities:

- Test image: `sha256:cdf91b32ae8e6449c370ad0e6f967fa8602b4460b3b2c8870d02f916aa65b627`.
- MariaDB: `sha256:611a2fcc5fa7c6ceb8644c6f74b25ede004ff6c3a6b38c8f8c23d3bbf6c26430`.
- Final log: `build/m3-protocol-foundation/server-tests.log`, SHA-256
  `1db29488cf8e3ec5f3ca0151233e68a328915ce4052f0c4b2923754ed65ee573`.
- Pre-race passing log: `build/m3-protocol-foundation/server-before-race.log`, SHA-256
  `5fc0e9c4e48968c60c177b512323542569ec1df1274062fd49e7ccc453c0f22d`.

## Native attempt and remaining work

Companion task changed to idle/interrupted and CUA inventory showed Photo Agent stopped,
so a new observation attempt was justified. The already tested `a9a5a14` Debug app was
launched with `AAGEDAL_UI_TESTING=1`, session `m3-native-a9a5a14` and test-job seeding;
this isolates stores and credentials. CUA selection by exact app path failed with
`timeoutReached` after 5.1212 seconds. No controls were observed or marked passed.
The owned process (61932) was closed with TERM (exit 143); no unrelated app was killed.
Launch log: `build/m3-protocol-foundation/native-launch.log`. The initial incorrect
product path returned exit 127 before the actual product was launched. No permission
or XCTest authentication bypass was attempted.

Next implement durable namespace bindings, separate cache/pending journals, explicit
new-UUID create-and-rebind workflow, saved migration provenance, invitation selection,
capability-aware activation admission and offline recovery. Do not lift the existing
legacy activation gate before those paths are integrated. Native UI, supported-OS,
real image/model, performance and final release gates remain open. The checklist keeps
all 42 stable case IDs; human results remain absent and no manual case was advanced.
