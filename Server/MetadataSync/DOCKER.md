# Run the sync server with Docker

This package builds `aagedal-metadata-sync:local` from the PHP source in this
checkout. It has not been published to a container registry. The app image runs
Apache/PHP 8.3 with `pdo_mysql`; Compose adds MariaDB 11.4 and an optional Caddy
HTTPS proxy. It shares calendar metadata, not photo/video files.

## 1. Prepare the host

Use a Linux server with Docker Engine, the Docker Compose v2 plugin, Python 3,
and persistent disk space. Start with 2 GB RAM or more for the combined stack;
actual capacity depends on calendar size and concurrent clients. Backups need
storage outside this host as well.

Copy this repository's `Server/MetadataSync` directory to the server, including
its SQL files and `docker` directory. Keep it outside any public website root.
The directory is the deployment package; the rest of the Mac app is unnecessary.
Run the commands below from that directory.

For the included HTTPS proxy:

- Point a dedicated name such as `sync.example.com` at the server's public IP.
- If you publish an AAAA record, IPv6 must reach the same server correctly.
- Allow inbound TCP 80 and 443. UDP 443 is optional for HTTP/3.
- Ensure no existing service occupies those ports.

Caddy obtains and renews certificates when DNS and inbound connectivity are
correct. See [Caddy's HTTPS requirements](https://caddyserver.com/docs/quick-starts/https).
The Mac app requires valid HTTPS and refuses redirects: configure its final HTTPS
address directly.

## 2. Generate private configuration

```sh
python3 docker/setup.py --domain sync.example.com
```

This creates `.env` and owner-only files in `secrets/`:

- `db_password`: application database password.
- `db_root_password`: database administrator password.
- `setup_key`: one-time first-Mac/hosting-check key.

Setup refuses to overwrite an existing installation. Keep these files through
upgrades and backups; do not rerun setup to repair a running database. Secrets
are excluded from Git and the application image build context. Compose mounts
them as files; they are not encrypted at rest by Compose. The image generates
its private `/var/www/config.php` before starting Apache; the document root is
`/var/www/html`.

`.env` initially enables setup. It does not contain passwords. The available
settings are:

| Setting | Purpose |
| --- | --- |
| `SYNC_DOMAIN` | Dedicated public hostname for Caddy |
| `SYNC_SETUP_ENABLED` | `true` during first-device setup; set `false` afterward |
| `SYNC_HTTP_PORT` | Localhost HTTP port; default `8080` |
| `SYNC_SECRETS_DIR` | Optional alternate secret directory; default `./secrets` |

## 3. Build and start with HTTPS

```sh
docker compose -f compose.yaml -f compose.https.yaml up -d --build --wait
docker compose -f compose.yaml -f compose.https.yaml ps
curl --fail https://sync.example.com/index.php
```

The response should be JSON identifying `aagedal-metadata-sync`, with PHP and
MySQL-driver checks passing. A redirect or HTML page indicates the wrong address
or proxy configuration. Certificate issuance can take longer than container
startup; inspect `docker compose -f compose.yaml -f compose.https.yaml logs proxy`
if HTTPS is not ready.

The database has no published port. The app's HTTP port is bound to localhost.
MariaDB data and Caddy certificate state use persistent named volumes. The database
initializes all three SQL schemas in explicit order **only on an empty data volume**.
The app health check verifies HTTP discovery, database connectivity, required
InnoDB tables, and the bootstrap row. It does not prove external HTTPS or a full
two-Mac sync cycle.

If you already operate an HTTPS reverse proxy, omit the HTTPS override:

```sh
docker compose up -d --build --wait
```

Forward your HTTPS hostname to `http://127.0.0.1:8080` on this host. Preserve POST
bodies and the `X-Aagedal-*` headers. Allow at least 1 MiB request bodies and
responses up to 4 MiB. A proxy in another container must share a network and use
`app:80`; its own localhost is not this service. Do not expose port 8080 as a public
HTTP alternative. Local HTTP is for the proxy and diagnostics, not the Mac client.

## 4. Connect the first Mac

Open `secrets/setup_key` locally with a trusted editor and copy its contents.
Do not put the key into a URL or share it with participants.

1. In the app, open **Settings → Metadata Sync → Hosting Checks**.
2. Enter `https://sync.example.com/`, run the server check, and run the database
   check with the setup key.
3. Under **Calendar Sync**, enter the same URL and a device name.
4. Expand **Server administrator: connect the first Mac**, paste the setup key,
   and choose **Connect First Mac**.
5. Edit `.env` so `SYNC_SETUP_ENABLED=false`, then run:

   ```sh
   docker compose -f compose.yaml -f compose.https.yaml up -d --wait
   ```

Compose recreates the app because its environment changed. A plain `restart`
does not apply changed environment settings. Use the base command without the
HTTPS override if you chose your own proxy.

Setup and private hosting checks are now disabled. Public discovery and ordinary
calendar sync remain available. Bootstrap cannot enroll another first owner once
the database already has one, even if setup is accidentally enabled again.

Publish a disposable shared calendar from the first Mac, invite a second Mac, and
activate the received calendar on a local job. Test edits in both directions and
an offline/reconnect cycle before enabling metadata processing on production jobs.
Use **Template-enabled — requires 3.0** only with compatible app versions; classic
and template calendars are separate namespaces.

## Backups and restoration

Back up the database regularly and before upgrades:

```sh
python3 docker/database.py backup backups/before-upgrade.sql
```

The helper writes a consistent SQL dump with private permissions and refuses to
overwrite a file. Keep an encrypted off-host copy of the dump, `.env`, and
`secrets/`. Also preserve the owner Mac's app data and Keychain identity: a database
backup does not replace a lost device key. Certificate volumes can be backed up
separately to avoid reissuance after a host loss.

To restore a **trusted backup**, stop requests first. This operation replaces
table contents; do it only when recovery is intended:

```sh
docker compose -f compose.yaml -f compose.https.yaml stop proxy app
python3 docker/database.py restore backups/before-upgrade.sql --replace
docker compose -f compose.yaml -f compose.https.yaml up -d --wait
```

With an external proxy, stop only `app`. On a replacement host, restore the
original `.env` and `secrets/`, start only `database` with `docker compose up -d
--wait database`, then restore before starting the app/proxy. Keep the same
hostname where possible. The helpers use the same default Compose project; if
you chose a custom name, set `COMPOSE_PROJECT_NAME` consistently for every command.

A backup can contain older calendar revisions than the Macs have saved. Clients
deliberately pause in that case. Restore a current backup, or deliberately detach
and publish the retained local programming as a new calendar; do not edit revision
numbers to force acceptance. Test restoration before depending on the backup.

## Updates

1. Back up, retain the old source/image version, and read the new release notes.
2. Update the deployment files without replacing `.env` or `secrets/`.
3. Stop the app/proxy before any required schema migration.
4. For this release's additive schemas, run `python3 docker/database.py migrate`.
   This reapplies the three bundled files in order. It is not a general migration
   framework: future releases may require additional steps. MariaDB init scripts
   do not run again on an existing volume.
5. Pull dependencies, rebuild, and recreate:

   ```sh
   docker compose -f compose.yaml -f compose.https.yaml pull database proxy
   docker compose build --pull app
   docker compose -f compose.yaml -f compose.https.yaml up -d --wait
   ```

6. Verify HTTPS, health, and a disposable calendar sync again.

For an external proxy, pull only `database` and omit `compose.https.yaml`.
The base images track PHP 8.3, MariaDB 11.4, and Caddy 2 updates; they are not pinned
to immutable digests. For controlled production releases, record/pin tested image
digests and use versioned tags for your app builds. Do not automate major database
upgrades or assume an older database engine can open a newer data volume.

`docker compose down` removes containers but retains database volumes. **Do not use
`down -v` on a live installation**: it removes persistent database/certificate
volumes. The tests use that flag only for disposable installations.

## Use the app image with an existing database

Build with `docker build -t aagedal-metadata-sync:local .`. The image requires
secret files mounted at `/run/secrets/db_password` and `/run/secrets/setup_key`.
You can override their paths using `SYNC_DB_PASSWORD_FILE` and `SYNC_SETUP_KEY_FILE`.
Configure `SYNC_DB_HOST`, `SYNC_DB_PORT`, `SYNC_DB_NAME`, and `SYNC_DB_USER` as
needed; defaults are `database`, `3306`, `sync`, and `sync`. Set
`SYNC_SETUP_ENABLED=true` only for enrollment. Install all schemas before startup.
The image alone does not create a database or supply HTTPS.

Use `docker buildx build --platform linux/amd64 --load -t aagedal-metadata-sync:local .`
when building explicitly for an x86 VPS. A normal build uses the host architecture.
An ARM build does not establish that an x86 image has been tested. Registry
publication and multi-platform release automation are not included here.

## Verify the package locally

Run `python3 tests/docker-smoke.py` from this directory with Docker available.
It builds the production image, uses a unique disposable database and localhost
port, tests enrollment/sharing, container recreation, backup/restore and setup
closure, and validates the Caddyfile. It removes its own test volumes afterward.
It does not exercise public DNS or certificate issuance.

## Troubleshooting

- `database` unhealthy: inspect its logs and available disk space. Changing the
  password file does not change the password in an already initialized database.
- `app` unhealthy: check `docker compose logs app`, required schema tables, and
  database credentials. No secrets should appear in diagnostic output.
- HTTPS fails: check DNS, any AAAA record, firewall rules, port conflicts, and
  Caddy logs. Do not disable TLS checks in the Mac app.
- Setup is rejected: check `.env`, recreate the app, and confirm this database
  has not already enrolled its first owner. Additional Macs use invitations.
- HTTP 413: reduce calendar content. Documents are capped at 1,000,000 bytes;
  complete requests are capped at 1 MiB.

Related: [manual PHP/SQL setup](MANUAL-SETUP.md), [protocol and usage reference](README.md),
[MariaDB image initialization documentation](https://hub.docker.com/_/mariadb).
