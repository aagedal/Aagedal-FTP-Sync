# Metadata sync Docker packaging — 20 September 2026

Built the production Apache/PHP image as `aagedal-metadata-sync:local` on
`linux/arm64`. It is a local image, not a published registry release. The Dockerfile
uses the official PHP 8.3 Apache image and installs `pdo_mysql`; Compose supplies
MariaDB 11.4, persistent database storage, generated file-based secrets, and an
optional Caddy 2 HTTPS proxy.

## Validation

- Fresh Compose build/start completed with database and app healthy.
- `tests/docker-smoke.py` passed against the production image: public discovery,
  private-file exclusion, database hosting check, first-device bootstrap,
  protocol-3 publication, invitation and receipt by another device.
- Removing/recreating containers without removing volumes retained the calendar
  and device credentials.
- The documented database helper created a private transaction-consistent dump,
  restored it after a calendar update, and reapplied the bundled additive schemas.
  Restored content matched the saved document.
- Recreating the app with setup disabled rejected hosting checks and a new
  first-device enrollment, while existing-device sync remained available.
- HTTPS Compose configuration and Caddyfile validation passed. Public DNS,
  external routing, and certificate issuance were not exercised.
- An image-only inspection confirmed `pdo_mysql` was installed and no generated
  private config, raw setup key, or test directory was baked into the image.
- Python helper compilation and `git diff --check` passed.

The final rebuild tightened the Dockerfile-specific context allowlist to the
three API files and required runtime files; the runtime contents were unchanged.
The Caddyfile was formatted and revalidated. Both disposable Compose projects and
their test volumes were removed. The application image remains available locally.

No production server was changed. No amd64 runtime test, image publication, or
public HTTPS acceptance is implied. Build on the target VPS or use the documented
Buildx platform selection before deployment.

Local evidence is retained in `build/docker-sync-validation-20260920/` (ignored by
Git). The reproduction command is `python3 tests/docker-smoke.py` from
`Server/MetadataSync` with Docker available; it creates and removes its own unique
test project and credentials.

Guides: [Docker](../../Server/MetadataSync/DOCKER.md),
[manual PHP/SQL](../../Server/MetadataSync/MANUAL-SETUP.md).
