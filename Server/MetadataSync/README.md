# Metadata sync hosting check

This is the first hosting compatibility milestone, not a working calendar sync server. It proves that a chosen host can serve the app's protocol over HTTPS and that PHP can read/write Unicode data in an InnoDB transaction. It does not publish, import, or synchronize metadata programming.

The open-source app has no default sync provider or domain. In **Settings → Metadata Sync**, users enter their own HTTPS URL. Both a subdomain (`https://sync.example.org/`) and a subdirectory (`https://example.org/metadata-sync/`) are supported. The client requests `index.php` beneath that base URL; URL rewriting is unnecessary. The address is saved locally, outside job configuration exports. Hosting check keys are not persisted.

## Requirements

- PHP 8.2 or newer and the `pdo_mysql` extension. Choose a currently supported PHP version offered by the host.
- A MySQL/MariaDB database with InnoDB and `utf8mb4` support.
- A valid HTTPS certificate for the chosen hostname.
- File upload access and a private location for database configuration.
- Permission to create one probe table initially, then SELECT, INSERT, and UPDATE its rows.

No persistent process, cron task, URL rewriting, Composer dependency, or WebSocket is required for this check.

## 1. Check PHP before configuring MySQL

Upload **only `public/index.php`** into the chosen subdomain's public web directory. If it already has an index file, use a new empty subdirectory instead of overwriting it.

Open the HTTPS URL ending in `/index.php`. Expect JSON with:

```json
{
  "service": "aagedal-metadata-sync",
  "protocolVersion": 1,
  "stage": "hosting-check",
  "checks": [
    { "name": "PHP runtime", "passed": true },
    { "name": "MySQL driver", "passed": true }
  ]
}
```

This public discovery request does not load credentials or access MySQL. It does not prove the database is ready. If PHP source downloads or displays as text, remove the file and correct PHP execution before uploading any private configuration.

In the Mac app, enter the base URL in **Settings → Metadata Sync**, choose **Save Server**, then **Check Server**. No credentials are required for this first check. HTTPS certificates are validated normally; redirects are refused, so enter the final URL directly.

## 2. Configure the database privately

Create a dedicated database in your hosting panel. Record its actual database host, port, database name, username, and password; the database host need not match the sync domain.

Import `schema.sql` into that database using phpMyAdmin. It creates only `aftpsync_hosting_probe`, without changing existing tables.

Run locally:

```sh
python3 create-config.py
```

The script prompts for connection details with the password hidden, and creates two files with owner-only permissions:

- `config.php`: database settings and a hash of the hosting check key.
- `hosting-check-key.txt`: the randomly generated key to paste into the app.

Both filenames are ignored by Git. Keep the key file on your Mac. Never upload the key file, test fixtures, or an entire repository to the public website.

Upload `config.php` **outside every publicly served web directory**. The preferred layout is:

```text
private application directory/
  config.php
  public/                 ← subdomain document root
    index.php
```

If your hosting provider fixes the subdomain directory inside another website's public root, put `config.php` in an account-private directory outside that root and change the `$configPath` assignment in the deployed `index.php` to its absolute server path. The current default is the parent of `public/`; do not use that default if the parent is also publicly served. Do not rely on the `.php` extension or a hidden filename alone to keep configuration private.

`config.example.php` documents the settings for manual setup. Do not use the example placeholders or the disposable test credentials in a real deployment.

Use a server filesystem path for the configuration, not an FTP-relative path: an FTP account's `/` may represent a different directory on the server. The authenticated check verifies that PHP can read the chosen file under the host's permissions and filesystem restrictions. Keep provider-specific path changes and deployment notes in local, ignored artifacts; the public package describes the generic layout only.

## 3. Run the database check

In **Settings → Metadata Sync**, paste the contents of the local `hosting-check-key.txt` into **Hosting check key**, then choose **Check Database**. The key is sent only to the entered HTTPS endpoint, in an HTTP header, and is cleared from the form after the check.

The endpoint verifies the table uses InnoDB before writing. It inserts a uniquely identified probe row, updates it with Norwegian characters and an emoji, reads it back, rolls the transaction back, and checks that the row disappeared. It neither reads nor changes any calendar/job tables. A successful response includes five passing checks.

After the trial, set `hosting_checks_enabled` to `false` in the private configuration. This disables authenticated database probing while leaving public discovery available. Delete the local temporary key when no longer needed. Calendar/device authentication is a separate future feature; this setup key must never become a shared user login.

## Troubleshooting

| Result | Meaning / next check |
| --- | --- |
| Certificate failure | Ensure the certificate includes this subdomain; never disable verification. |
| 403 or 404 | Check the subdomain document root, upload path, file permissions, and web access rules. |
| Redirect | Enter the final HTTPS base URL directly. |
| HTML instead of JSON | A default page, login page, or error document was reached. |
| MySQL driver check fails | Enable `pdo_mysql` or choose a PHP configuration that includes it. |
| 401 | The setup key does not match the configured SHA-256 hash. |
| 503 | Check PHP version, private config path, DB credentials, schema import, and InnoDB/Unicode support. |
| 404 on database check only | `hosting_checks_enabled` may be disabled. |

The API deliberately does not return database passwords, hostnames, paths, or raw PHP/PDO exceptions. Inspect configuration on the host instead of posting credentials or `phpinfo()` output publicly.

## Verification and limits

Local integration tests run against disposable PHP and MariaDB containers with no published ports. The test project uses an in-memory database filesystem and synthetic credentials; it never connects to your hosting:

```sh
docker compose -p aftpsync-hosting-check -f tests/compose.yaml up --build --abort-on-container-exit --exit-code-from test
docker compose -p aftpsync-hosting-check -f tests/compose.yaml down
```

Run the app's focused tests from the repository root:

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync -destination 'platform=macOS' \
  -only-testing:AagedalFTPSyncTests/MetadataSyncServerTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
```

Passing preflight does not establish acceptable polling load, backup restoration, durable commit/reconnect behaviour, multi-user isolation, or production sync correctness. Those require the next implementation and deployment tests.

## Next milestone

Keep the connection protocol provider-independent, then add independently identified calendars, invite/device authentication, full-calendar and date-range permissions enforced by the server, revision-checked edits, durable change delivery, explicit deletions/removals, and local offline queues. Preserve competing versions and validate the combined schedule before allowing remote changes to drive metadata application. FTP credentials, local paths, and local processing policies remain outside shared calendar data.

Reference: [PDO transactions](https://www.php.net/manual/en/pdo.begintransaction.php).
