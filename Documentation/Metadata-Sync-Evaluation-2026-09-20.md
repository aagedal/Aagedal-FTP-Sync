# Metadata sync evaluation — 20 September 2026

Reviewed source: `a4cfed1a9245dfd5176d25e384086a30f24815d7`.

Implementation follow-up: the four prioritized findings were addressed in the
working tree later on 20 September. See [fix validation](Testing/2026-09-20-Metadata-Sync-Fixes.md).
The findings below describe the original reviewed revision.

## Assessment

The existing PHP/MariaDB and Swift design is viable for a small team. The review
found three reproducible bugs and a retry-policy gap worth fixing before changing
hosting. Nothing in these results establishes that the deployed server is broken
or healthy: its address, deployment contents, and reported failure were not
available during this evaluation.

This was an evaluation, not a production-code change. Temporary Swift audit probes
were removed after execution. No production server or credentials were used.

## Findings, in recommended fix order

### P1 — Activated-template calendars cannot use conflict review

Location: `AagedalFTPSync/Models/MetadataCalendarMerge.swift:32–37`.

`MetadataCalendarConflictReview.plan()` validates all three documents through
`LegacyMetadataCalendarGate`, even when the binding and remote calendar both use
the template namespace. An activation anywhere in any document causes the review
to throw before presenting resolution choices. Ordinary changes to a photographer
name can trigger this if the calendar also contains an activated copyright field.

The coordinator retains the conflict, and its normal refresh skips conflicted
bindings. The conflict sheet's failure branch has no Apply button. Local data is
retained, but the normal resolution workflow cannot resume sync.

Reproduced with an activated copyright baseline and competing photographer-name
edits. The underlying merge planner correctly produced one conflict; the review
wrapper threw `template_protocol_required`.

Fix: validate binding, remote compatibility, and all three documents against the
binding's namespace. Preserve rejection of activated content in legacy calendars.
Add an end-to-end coordinator regression covering review, user choice, upload,
restart, and preserved activation markers.

### P2 — Version-3 installation failures are misreported as protocol mismatches

Locations: `Server/MetadataSync/public/index.php:11–27` and
`AagedalFTPSync/Sync/MetadataCalendarClient.swift:150–170`.

Early server failures such as missing `config.php` return protocol 3 without a
capability declaration. The client rejects this envelope before translating the
known error. Its later installation-error translation also only permits protocol
1 or 2. Consequently a simple installation fault tells the user to update the
app/server instead of identifying the missing configuration.

Reproduced by feeding the real early-error envelope shape to the production
decoder: `not_configured`, HTTP 503, protocol 3 became “This server uses an
unsupported protocol version. Update the app or server.”

Fix: recognize a strict allowlist of document-free installation errors before
successful-response capability validation. Keep capability checks mandatory before
accepting any calendar content. Check for missing `templates.php` explicitly too;
the current unconditional require falls into a generic outer error handler.

### P2 — Create and update accept different calendar sizes

Locations: `Server/MetadataSync/public/live.php:247–266` and `303–304`.

The request ceiling is 1,048,576 bytes, but updates also cap the encoded document
at 1,000,000 bytes. Creation does not apply that document ceiling. A user can
therefore publish a calendar successfully and subsequently be unable to send even
a small edit until reducing its content.

Reproduced against PHP/MariaDB with 63 valid nonoverlapping clips, each containing
a 16,000-byte description:

| Request | Request bytes | Result |
| --- | ---: | --- |
| Create | 1,022,235 | HTTP 200, revision 1 |
| Put the same document | 1,022,207 | HTTP 413, `calendar_too_large` |
| Get | 76 | HTTP 200, revision still 1 |

Fix: share document serialization and size validation between create and update,
including range-merged updates. Expose a consistent client-side limit with room
for the request envelope. Test ASCII and multibyte boundary cases. Existing
oversized calendars need a clear reduction/recovery message.

### P2 — Server failures do not receive the connection backoff

Locations: `AagedalFTPSync/Sync/MetadataCalendarCoordinator.swift:241–244`,
`503–514`, `532`, and `547`.

Static finding: only a selected set of `URLError` values enters the account
cooldown. HTTP 503 from this server becomes `MetadataSyncFailure`; a proxy's 429,
502, or 503 can instead become a generic response error. Neither path contributes
to the cooldown. The client continues trying each linked calendar on subsequent
polls, and failed calendar listing does not update its successful-list timestamp.
This increases load precisely when the database or hosting is unavailable.

Fix: preserve HTTP status and Retry-After as structured transport information.
Back off with jitter for 429 and transient 5xx, coalesce failures per server, and
retain manual retry. Treat authorization, validation, and conflicts separately.
Add clock-controlled tests covering service failures as well as disconnected
network errors. This gap was established by source inspection, not a load test.

## Further improvements

1. **Cheap unchanged polls.** Each `getCalendar` returns the full permitted
   document even when the revision is unchanged. Add a known-revision request and
   a document-free unchanged response, still checking authentication, membership,
   namespace, and scope. For illustration, a 50 KiB response every ten seconds
   for 24 hours is about 422 MiB per device per calendar, excluding overhead. Real
   intervals include request duration and traffic stops when the app is closed.
2. **Reuse networking sessions.** `MetadataCalendarClient.send()` builds and
   invalidates a URLSession for each operation. A reusable ephemeral session can
   support connection reuse while retaining the no-redirect/no-cookie policy.
3. **Check actual service readiness.** Public discovery checks runtime/driver;
   the administrator database check exercises the probe table. Neither establishes
   end-to-end calendar operation. Add an authenticated, document-free check of all
   required tables, schema versions, InnoDB engines, and required files. Avoid
   promising readiness based only on table existence.
4. **Make server failures diagnosable.** Preserve generic public error responses,
   but add request IDs and sanitized server-side error categories, operation names,
   timing, and schema readiness. Current catch-all logging cannot distinguish many
   deployment and database failures. Do not log keys, invitations, or documents.
5. **Operational recovery.** Add supported owner/device-key recovery, calendar
   retirement, and documented backup restoration drills. The current server has
   a 100-owned-calendar limit and no calendar-delete API; detaching does not free
   that quota. Backups alone do not solve lost owner credentials.

These are follow-up improvements, not evidence that a VPS or a backend rewrite is
required. Polling can remain appropriate after reducing unchanged-response cost.

## Verification performed

Environment: arm64 macOS, Xcode 27.0 (`27A266a`), disposable Docker services built
from the repository's PHP 8.3/MariaDB 11.4 test configuration.

| Check | Result |
| --- | --- |
| Existing focused native suite | 54 discovered; 53 passed, one loopback test skipped |
| Existing PHP suite | 162 PASS assertions; test container exit 0 |
| Native Swift/PHP loopback test, run separately | Passed; no skip |
| New temporary intended-behaviour probes | Both failed as expected, reproducing findings 1 and 2 |
| Additional real server size probe | Reproduced finding 3 |

The loopback integration test exercises real Swift encoding/decoding, registration,
invitations, publication, receipt into another job, independent offline edits,
competing edits with conflict choices, and a third device with date-limited access.
It uses classic protocol 2. The PHP suite covers protocol 3, while the selected
native protocol-3 tests use injected transport. This is not a complete real-wire
protocol-3 acceptance pass, a two-physical-Mac UI run, a performance benchmark, or
a production HTTPS/hosting check.

Initial sandboxed test attempts could not write Xcode caches or start OrbStack.
Authorized reruns completed. Both disposable Compose projects were removed with
`down -v`, including the loopback port. OrbStack was started for the review.

Local evidence, ignored by Git, is retained under `build/sync-review-20260920/`:

- `aftpsync-sync-review-native.log`
- `aftpsync-sync-review-php.log`
- `aftpsync-sync-review-wire.log`
- `aftpsync-sync-review-probes.log`
- `aftpsync-sync-review-size.log`
- `aftpsync-review-audit-probes.swift`
- `aftpsync-review-size-probe.php`
- Cleanup logs for both Compose projects.

The Swift probe source is an extension for
`MetadataCalendarProtocol3ClientTests.swift`; it was temporarily appended to that
file to use its existing fixtures. It is deliberately absent from the permanent
test target until the corresponding fixes are implemented.

## Deployment follow-up

Obtain the current HTTPS base address and observed failure, then verify public
discovery/TLS and compare deployed PHP files and database migrations. Use a
dedicated disposable calendar and explicitly available test identities for any
write-based acceptance checks. Confirm real two-Mac reconnect/restart behaviour
and backup recovery before relying on this server for production programming.
