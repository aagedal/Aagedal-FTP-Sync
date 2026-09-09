# Metadata calendar sync server

An optional, provider-independent PHP/MySQL service for Aagedal FTP Sync. Users enter their own HTTPS server address in **Settings → Metadata Sync**. Subdomains and subdirectories are supported; the app calls `index.php` below the selected URL. There is no default sync domain.

The first implementation shares whole calendars or a date range, supports multiple editors and read-only invitations, and polls approximately every ten seconds while the Mac app is running. It needs no daemon, cron job, URL rewriting, Composer installation, WebSocket, or external login provider.

## What is shared

Shared records contain photographer identifiers, names, filename initials, creator/copyright, day rows, and clips with their names, times, text, keywords and GPS locations. FTP connections, passwords, paths, processing policies and photographer work hours are excluded. The server rejects unknown fields in shared documents.

Date ranges are half-open intervals: the first day is included through the end of the last selected day. **Only clips entirely inside the interval are shared. Boundary-crossing clips are excluded.** Day rows must fit entirely within the interval in the calendar's time zone. Limited recipients see only photographers referenced by visible clips or day rows. They can edit clips using those photographers, but cannot modify photographer details or add new photographers. Full-calendar editors manage those details.

## Requirements

- PHP 8.2+ with `pdo_mysql`, using a supported PHP version offered by the host.
- MySQL/MariaDB with InnoDB and `utf8mb4`.
- A valid HTTPS certificate and file upload access.
- A private filesystem location outside **every** publicly served directory for configuration.
- A dedicated database. Installation needs table creation privileges; operation needs SELECT, INSERT, UPDATE and DELETE on these tables.

HTTPS protects transport. Calendar contents are stored as ordinary JSON in the database, **without end-to-end encryption**. The server administrator can read them. Back up the database and protect hosting access accordingly.

## Install or upgrade

1. Import `schema.sql` and `schema-live-sync.sql` into the dedicated database, using phpMyAdmin or the MySQL CLI. Both are additive and use `CREATE TABLE IF NOT EXISTS`. For an existing hosting-check installation, import only `schema-live-sync.sql`.
2. Upload **both** `public/index.php` and `public/live.php` into the endpoint's public directory. Preserve any existing deployment-specific `$configPath` assignment in `index.php` when upgrading. Do not upload the repository, tests, SQL files, credentials or key files into that directory.
3. For a new installation, run `python3 create-config.py` locally. It prompts for the database connection and creates `config.php` and `hosting-check-key.txt` with owner-only permissions. They are ignored by Git. Existing installations keep their current config and key.
4. Put `config.php` outside all public web roots. The generic layout is:

   ```text
   private application directory/
     config.php
     public/                 ← document root
       index.php
       live.php
   ```

   If the host uses another layout, change only `$configPath` in the **deployed** `index.php` to point at the actual private filesystem path. FTP-relative paths may differ from server filesystem paths. Keep provider-specific changes in ignored local artifacts. Do not rely on a hidden filename or `.php` extension alone to protect configuration.
5. Add `'bootstrap_enabled' => true,` to the private configuration temporarily. Keep its existing `setup_key_sha256` hash. See `config.example.php` for all options.
6. Open **Settings → Metadata Sync → Hosting Checks**. Save the HTTPS base URL, check the server, and optionally check the database with the temporary hosting-check key. Redirects are refused; enter the final address directly.
7. In **Calendar Sync**, enter the same URL and a device name. Expand **First device on a new server**, paste the setup key, and choose **Register First Device**.
8. Set both `bootstrap_enabled` and `hosting_checks_enabled` to `false` in the private configuration and re-upload it. The setup key is no longer used during normal sync. Do not send it to other participants.

Public GET discovery remains protocol 1 (`stage: hosting-check`) for compatibility. Calendar requests select protocol 2 with an HTTP header. A successful hosting check alone does not establish that the new tables and API were installed.

## Use in the app

- **Publish:** Select an existing local job, name the calendar, optionally select dates, and publish. Only the shared metadata subset is transmitted. A job can link to one calendar. Saved edits synchronize automatically; unsaved or invalid editor drafts pause incoming updates for that job.
- **Invite:** The owner selects a server calendar, editor/read-only permission and optional date range, then creates an invitation. Copy and privately share the server URL and invitation. Each invitation expires in 24 hours and can enroll one device. Make a separate invitation for each Mac, including additional Macs used by the owner.
- **Receive:** On the other Mac, join with the invitation, select the calendar and a local job, then choose **Receive Calendar…**. Empty metadata programming receives directly. If the job already has programming or a calendar link, the app offers **Duplicate and Receive**. The confirmation names the original and new jobs before anything changes. The copy retains connections, folder bookmarks and local processing policies, and receives only the shared calendar content. The original retains its programming. Automatic running and startup at app launch are disabled on both jobs; review and enable the copy when ready. Transfer history stays with the original job. Cancelling the confirmation leaves it unchanged.
- **Resolve:** Changes to different clips merge automatically. Competing changes to the same clip/profile/day rows, deletion versus edit, or a merged invalid schedule pause sync. The local job and remote version remain saved. Review both versions in settings and explicitly choose one. This choice replaces the shared portion as a whole; edit the chosen version afterward to incorporate other changes.
- **Detach:** Stops syncing that job and keeps its local programming. It does not delete the server calendar or revoke membership.
- **Revoke:** Owners can revoke a device's membership or invalidate invitations. Revocation prevents future sync; it cannot erase copies already downloaded. Revoking invitations does not remove existing memberships.

Each Mac stores a random device key in Keychain and separate sync state in application support. Server-side tables contain credential hashes. Registration persists the local identity before contacting the server, so a lost response can be retried safely. Do not delete an owner's local identity or Keychain entry casually: this version has no owner recovery/transfer UI. Keep secure device/database backups. The same Mac can retain identities for several independently configured servers.

## Consistency and limits

The server locks each calendar in an InnoDB transaction, checks current membership, and compares the expected revision before replacing a validated document. A stale writer receives HTTP 409 with only its permitted snapshot. Range writes preserve all hidden records, validate old/new scope and prevent hidden identifier replacement. Revocation uses the same calendar lock as writes and invitation redemption.

The local job is the durable queue for saved edits; a separate persisted baseline supports three-way merging after reconnect/restart. Receiving into a duplicate saves an approved local receipt journal first, then saves the paused original and populated copy together in one jobs-file write. An interrupted link resumes using the same copy identifier, preserving later edits. Storage failures remain visible and a pending link can be retried or cancelled; cancelling a pending link retains any jobs already saved. Successful writes and lost responses are reconciled against server snapshots, so a retry cannot silently overwrite newer edits. Explicit deletion is represented by absence from the complete scoped document with a matching revision; it is not an unversioned omission.

This is polling sync, not instant push. One request carries at most 1 MiB; one calendar supports up to 500 photographers, 2,000 clips and 5,000 day rows, with bounded text fields. Dates are milliseconds since Unix epoch, from 1970 through 2099. The server limits a device to 100 owned calendars and a calendar to 100 unexpired invitations. The app displays server rejections and retains local edits. Large calendars, archival cleanup, owner recovery, key rotation, member scope changes and end-to-end encryption remain future work. To change a member's scope, revoke it and issue a new invitation. If the received date range or calendar time zone changes, the app pauses the existing link and keeps local programming. Detach and receive again to review the new scope; populated jobs use the duplicate-and-receive flow.

A server revision older than the saved local baseline also pauses sync, including conflict resolution. Restore a current server backup, or detach and publish the retained local programming as a new calendar. This protects against silently rolling a Mac back to an older database snapshot.

Test this implementation with disposable programming before using it to drive live metadata processing. Confirm two-Mac operation, reconnect behavior, acceptable polling load and backup restoration on the actual deployment.

## Troubleshooting

| Result | Check |
| --- | --- |
| TLS error or redirect | Certificate and final HTTPS base URL; do not disable certificate checks. |
| HTML instead of JSON | Document root and PHP execution. Remove files if PHP source is exposed. |
| Hosting works, sync fails | Upload `live.php`, import the additive live schema, and check private configuration. |
| First-device setup rejected | Enable bootstrap, use the correct setup key, or use an invitation if an owner already registered. |
| 401 | Correct device identity and Keychain credential. The setup key is not a device key. |
| 403 | Role/range restriction, revoked membership or invalid invitation. |
| 409 | The app merges a newer revision or shows a conflict. |
| 422 | Invalid/overlapping schedule, duplicate initials or a server limit. |
| 503 | PHP driver, private configuration, database permissions, InnoDB tables and server logs. |

Responses and logs deliberately omit database credentials, hostnames, filesystem paths and raw PHP/PDO exceptions. Do not post credentials or `phpinfo()` publicly.

## Verification

The disposable integration suite uses PHP 8.3 and MariaDB 11.4 with synthetic credentials, an in-memory database filesystem and no published ports. It does not connect to a deployed server:

```sh
docker compose -p aftpsync-hosting-check -f tests/compose.yaml up --build --abort-on-container-exit --exit-code-from test
docker compose -p aftpsync-hosting-check -f tests/compose.yaml down
```

From the repository root, run native sync and editor tests:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -only-testing:AagedalFTPSyncTests/MetadataSyncServerTests \
  -only-testing:AagedalFTPSyncTests/SharedMetadataCalendarTests \
  -only-testing:AagedalFTPSyncTests/MetadataCalendarCoordinatorTests \
  -only-testing:AagedalFTPSyncTests/MetadataProgrammingCoordinatorTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
```
