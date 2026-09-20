# Manual PHP/MySQL or MariaDB setup

Use this guide for shared hosting or a web server you administer yourself. Docker
is optional; [the Docker guide](DOCKER.md) packages the same API and schemas.

The server exchanges calendar metadata only. It does not store your photos,
FTP passwords, destination paths, or processing policies. Calendar content is
stored unencrypted in the database; the hosting administrator can read it.

## 1. Confirm hosting requirements

Ask your host or check its control panel for:

- PHP **8.2 or newer**, on a supported release, with **PDO MySQL (`pdo_mysql`)**.
- MySQL or MariaDB with **InnoDB** tables and **utf8mb4** support.
- A dedicated database and a database login allowed to create tables during setup.
  Normal operation needs SELECT, INSERT, UPDATE, and DELETE on the sync tables.
- A valid HTTPS certificate for the final server address.
- File upload access and a directory outside **every** public website root for
  the private configuration file.
- Permission to receive POST requests and the `X-Aagedal-*` request headers.
  Proxies/firewalls must allow at least 1 MiB request bodies and 4 MiB responses.

No Composer, cron, background daemon, WebSocket, URL rewrite, or third-party login
provider is required. If your host cannot provide private file storage or InnoDB,
choose another host or the Docker deployment.

Choose a permanent HTTPS base address, for example:

```text
https://sync.example.com/
https://example.com/metadata-sync/
```

The app calls `index.php` below that address. Enter the final address directly;
HTTP-to-HTTPS and hostname redirects are refused by the app. Do not put passwords
or setup keys in the address.

## 2. Create the database

In your hosting control panel, create a dedicated database and database user.
Record the host, port (usually 3306), complete database name, username, and password.
Provider-assigned names may include an account prefix. The SQL host may differ
from your website or FTP hostname; use the provider's value.

Open that database in phpMyAdmin and import these files **in this order**:

1. `schema.sql` — hosting-check probe.
2. `schema-live-sync.sql` — devices, bootstrap, classic calendars, memberships,
   and invitations.
3. `schema-template-sync.sql` — separate version-3 calendar tables.

Import all three even when starting with classic calendars. The current API checks
both namespaces. Confirm the imports succeeded and all nine tables use InnoDB.
Do not silently change the engine to work around an import error.

With MySQL CLI access, the equivalent commands are below. Replace the capitalized
placeholders with your actual settings; `-p` prompts without putting the password
in shell history:

```sh
mysql -h DB_HOST -P 3306 -u DB_USER -p DB_NAME < schema.sql
mysql -h DB_HOST -P 3306 -u DB_USER -p DB_NAME < schema-live-sync.sql
mysql -h DB_HOST -P 3306 -u DB_USER -p DB_NAME < schema-template-sync.sql
```

The MariaDB CLI can be used instead of `mysql`. The bundled schemas are additive;
they do not transfer classic calendar data to version 3. After setup, reduce the
runtime user's privileges if the host supports a separate migration login.

## 3. Generate the private configuration on your computer

From the downloaded `Server/MetadataSync` directory, run:

```sh
python3 create-config.py
```

Enter the database settings when prompted. The password input is hidden. The
script generates:

- `config.php` — database credentials and a hash of the setup key.
- `hosting-check-key.txt` — the random 64-character setup key itself.

Both files have private local permissions and are ignored by Git. The script
refuses to overwrite either file. Keep the key file on your computer; it must not
be uploaded into the website. Keep secure copies of both files.

For initial enrollment, open the generated `config.php` in a text editor and set:

```php
'hosting_checks_enabled' => true,
'bootstrap_enabled' => true,
```

Do not change `setup_key_sha256` or paste the plain key into that field.

## 4. Upload files into the correct locations

An ideal server layout is:

```text
private-application-directory/
  config.php
  public/                    ← HTTPS document root
    index.php
    live.php
    templates.php
```

Upload the three files from this package's `public/` directory to the public
endpoint. Upload `config.php` into the private parent directory. In this layout,
the bundled `index.php` already finds the correct configuration path.

Shared hosting often has a different layout:

```text
/home/account/private/metadata-sync/config.php
/home/account/public_html/metadata-sync/index.php
/home/account/public_html/metadata-sync/live.php
/home/account/public_html/metadata-sync/templates.php
```

For this example only, change the configuration-path assignment in the **deployed
copy** of `index.php` to:

```php
$configPath = '/home/account/private/metadata-sync/config.php';
```

Use the actual absolute filesystem path from your host. FTP-visible paths are not
necessarily the PHP server's filesystem paths. The web PHP process must be able
to read the configuration. Use the host's appropriate owner/group permissions;
do not make the file world-writable. If PHP's `open_basedir` blocks the private
path, have the host allow that path.

The configuration must be outside every public document root, including other
subdomains on the account. A hidden filename or `.php` extension is not a substitute
for a private directory. Upload **only** the three API files to the public endpoint,
not SQL files, tests, Docker files, your repository, or the key file.

## 5. Test hosting before enrolling a device

Open `https://YOUR_HOST/YOUR_PATH/index.php` in a browser. You should see JSON
identifying `aagedal-metadata-sync`, with PHP and MySQL-driver checks passing.
An HTML page, login page, download, or displayed PHP source means the deployment
is not ready. If PHP source is served publicly, remove the endpoint files until
PHP execution is fixed.

In the Mac app:

1. Open **Settings → Metadata Sync → Hosting Checks**.
2. Save the final HTTPS base address.
3. Run the server check.
4. Open your local `hosting-check-key.txt`, copy the key, and run the database check.

The database check verifies Unicode and a transactional test write that is rolled
back. It does not establish that the calendar API and every migration work; the
calendar test below is still needed. Public discovery never exposes credentials.

## 6. Connect the first Mac and close setup

1. Under **Calendar Sync**, enter the same server address and a device name.
2. Expand **Server administrator: connect the first Mac**.
3. Paste the setup key and choose **Connect First Mac**.
4. Once enrollment succeeds, set both flags in the private configuration to false:

   ```php
   'hosting_checks_enabled' => false,
   'bootstrap_enabled' => false,
   ```

5. Re-upload the private `config.php`, preserving its database credentials and key
   hash. Public discovery and calendar sync continue to work.

If OPcache is configured not to revalidate files, reload PHP or use your hosting
panel's cache/reset control after changing configuration or PHP code.

The Mac now uses a device credential stored in Keychain. The setup key is not its
normal sync password, and is not the invitation for additional users. Do not delete
the owner's app state or Keychain key to troubleshoot enrollment; there is no
owner-recovery/transfer UI in this version.

## 7. Test actual sharing

Use disposable calendar programming first:

1. On the owner Mac, choose an existing local job, **New shared calendar from this
   job**, give it a name, and choose **Activate Sync**.
2. Select the shared calendar, choose editor or read-only permission and an optional
   date range, then create an invitation.
3. Privately give another Mac the copied server URL and invitation. Each invitation
   enrolls one device and expires after 24 hours. Create a separate one per Mac.
4. On the receiving Mac, paste the complete invitation and choose **Join Calendar**.
5. Select the calendar and a local job, then choose **Activate Sync**. Joining alone
   does not link a job. A populated job uses **Duplicate & Activate Sync** so existing
   programming is preserved; review the paused copy before enabling it.
6. Save an edit on each Mac and check that the other receives it. Test independent
   offline edits, reconnection, an app restart, and an intentional conflict.

Use the sync status and **Sync Activity…** for failures. Polling occurs roughly
every ten seconds while the app runs; saved edits also trigger sync. Unsaved or
invalid metadata drafts can pause incoming changes. Read-only participants cannot
upload edits. Date-range participants see only clips entirely within their range.

For version 3, choose a template-enabled calendar only when all participating apps
support it. Classic calendars are separate and remain available. Migrating requires
an explicit new calendar and new invitations; installing PHP files never migrates
existing calendars automatically.

## Updates

Before upgrading, back up the database and save the currently deployed PHP files,
private configuration, and any customized `$configPath` assignment.

For an existing installation upgrading to this package:

1. Temporarily stop client sync during the maintenance window.
2. Import missing additive schemas in order, including `schema-template-sync.sql`
   after the live schema. Existing tables are not replaced by these imports.
3. Upload matching `index.php`, `live.php`, and `templates.php` together, preserving
   the deployed private configuration path.
4. Keep bootstrap disabled. If you temporarily enable hosting checks, disable them
   again after validation.
5. Reload PHP/OPcache if required and repeat a disposable calendar test.

Later releases may need additional migrations; follow their release instructions.
Do not overwrite `config.php` with the example file, regenerate device identities,
or copy rows between classic and template tables. Current sync fixes require no
SQL changes beyond the three existing schemas.

## Backups and recovery

Schedule database backups through your host and retain an encrypted off-host copy.
In phpMyAdmin, export the dedicated database with both structure and data. With
CLI access, a transaction-consistent InnoDB dump can be made as follows:

```sh
umask 077
mysqldump -h DB_HOST -P 3306 -u DB_USER -p --single-transaction --skip-lock-tables --no-tablespaces DB_NAME > sync-backup.sql
```

Use a new filename each time. Check the command's exit status: shell redirection
can leave an empty or partial file after a failure. With MariaDB use
`mariadb-dump` and its supported options. Preserve `config.php` separately, along
with the owner's app data and Keychain identity. The database contains credential
hashes, not recoverable Mac device keys.

To restore, stop sync access first and import a trusted backup into the dedicated
database using your host's recovery procedure. Verify credentials, table engines,
and all schemas before reopening access. Test restoration with a disposable
installation periodically.

Restoring an old database can return calendar revisions older than those on the
Macs. The app pauses rather than silently rolling programming back. Recover a
current backup or deliberately publish retained local programming as a new
calendar. Do not alter revision counters to bypass that protection.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| TLS or redirect error | Correct the certificate and use the final HTTPS base address. |
| Browser returns HTML | Check the URL, directory, PHP execution, and proxy/login rules. |
| Missing private config | Check the deployed absolute `$configPath`, PHP read permissions, and `open_basedir`. |
| Missing API file | Upload all three matching PHP files: `index.php`, `live.php`, `templates.php`. |
| Hosting works but calendars fail | Verify all three SQL imports, InnoDB, database privileges, and matching PHP versions. |
| First-Mac setup rejected | Bootstrap must be enabled and the setup key must match. An already-enrolled server uses invitations. |
| HTTP 401 | Check that the Mac retains its correct device identity and Keychain key. |
| HTTP 403 | Check invitation validity, membership, role, and date-range restrictions. |
| HTTP 409 | Let the app merge or open its conflict review. |
| HTTP 413 | Reduce content: documents are capped at 1,000,000 bytes and requests at 1 MiB. |
| HTTP 422 | Check schedule overlap, duplicate initials, field limits, and template validity. |
| HTTP 429 / 5xx | Check hosting/database logs. Updated clients back off and retain local edits. |

Do not post raw credentials, invitations, database dumps, or public `phpinfo()`
pages when requesting help. The app's copied sync diagnostics omit calendar
content, server addresses, and credentials.

For detailed sharing rules and protocol compatibility, see [the server reference](README.md).
