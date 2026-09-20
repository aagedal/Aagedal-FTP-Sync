# Metadata sync fixes — 20 September 2026

Working-tree changes based on `a4cfed1a9245dfd5176d25e384086a30f24815d7`,
following the metadata sync evaluation.

## Changes

- Conflict reviews validate against the binding's namespace, allowing activated
  template calendars while retaining legacy and cross-namespace rejection.
- Known, document-free installation errors are explained before capability checks.
  The server explicitly reports missing `templates.php` alongside missing `live.php`.
  Successful calendar responses still require the normal capability validation.
- Creation and update share one JSON serialization/1,000,000-byte limit helper.
  Date-range updates use that helper on the merged full document. Complete requests
  retain their separate 1 MiB ceiling. Size errors tell users to reduce content.
- HTTP 429 and transient 5xx failures carry structured status and Retry-After.
  Automatic refresh coalesces account failures, backs off with jitter, and respects
  both numeric and HTTP-date Retry-After headers. Manual retry still bypasses the
  cooldown. HTML/malformed service failures never become accepted calendar data.

## Validation

Xcode 27.0, macOS arm64. Final focused native run: **77 tests passed, zero failed,
zero skipped**. This includes the actual Swift/PHP loopback integration test,
template namespace coordinator, protocol-3 client, classic coordinator, merge,
protocol error, diagnostic, and paused-startup tests.

The new template conflict test resolves competing activated fields, preserves an
independent remote edit, persists the resulting baseline/activation markers, and
reopens it with a fresh coordinator without another upload. It uses injected
transport; the real-wire test covers classic protocol 2.

The disposable PHP/MariaDB suite passed **193 assertions**, exit 0. New checks cover
missing API/configuration files and ASCII/multibyte document boundaries for both
protocols: exactly 1,000,000 bytes accepted for create and update; one byte above
rejected; rejected updates preserve the revision/document and rejected creation
leaves no calendar.

`git diff --check` passed. No production endpoint, device keys, or invitations
were used. Both test Compose projects were removed with `down -v`.

Local logs are retained in the ignored `build/sync-fixes-20260920/` directory:
`aftpsync-sync-fixes-final.log`, `aftpsync-sync-fixes-php.log`, the earlier native
run, and cleanup logs.

## Deployment

Build/install the updated Mac client and upload the updated server PHP files,
preserving the deployed private configuration path. These fixes need no SQL
migration beyond the already-required schemas. Existing oversized calendars remain
readable but need content reduced before they can be updated under the documented
limit. Nothing has been deployed by this task.

The evaluation's optional improvements—unchanged-revision responses, reusable
network sessions, deeper readiness checks, and account recovery—remain separate
follow-up work.
