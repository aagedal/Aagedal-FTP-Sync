# Aagedal FTP Sync 2.0

A native macOS menu-bar utility for getting newsroom files where they need to go quickly. It is designed for photojournalists who deliver directly from a camera to a server and for picture desks that need the newest JPEG and RAW files within seconds.

Version 2.0 is a clean SwiftUI rewrite. It has no hard-coded server and does not bundle rclone.

## What is new

- Any number of independent sync jobs
- Local folders, FTP, implicit FTPS, and SFTP endpoints
- Remote → local, local → remote, and two-way synchronization
- Local → local and two-way local folder synchronization
- Per-job schedules from 2 seconds to 5 minutes
- Quick filters for JPEG, camera RAW, all photos, video, all files, or custom extensions
- Optional recent-file windows for busy assignment folders
- Original filenames and modification dates are preserved when the server supports it
- Passwords are kept in macOS Keychain, never in the jobs file
- Security-scoped folder bookmarks survive sandboxed app restarts
- SFTP host keys are pinned on first use; unexpected changes are rejected
- FTPS certificates use normal system trust validation
- New files are staged before atomic local replacement
- Remote path traversal and symbolic-link traversal are rejected
- Deletions are never propagated in version 2.0

## Requirements

- macOS 14 Sonoma or newer
- Xcode 16 or newer to build
- An FTP server with passive mode and `MLSD` or Unix-style `LIST` support
- Implicit FTPS normally uses port 990. Use SFTP when available.

## Build

Open `AagedalFTPSync.xcodeproj`, select the `AagedalFTPSync` scheme, choose your development team, and run.

The committed Xcode project is generated from [`project.yml`](project.yml) with [XcodeGen](https://github.com/yonaskolb/XcodeGen). Regenerate it after changing project structure:

```sh
xcodegen generate
```

Run the test suite:

```sh
xcodebuild test \
  -project AagedalFTPSync.xcodeproj \
  -scheme AagedalFTPSync \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

## First setup

1. Click the sync icon in the menu bar.
2. Choose **Create Sync Job**.
3. Configure the left and right endpoints and choose a direction.
4. For local endpoints, use **Choose…** so macOS can grant durable folder access.
5. Pick a quick file filter. **All photos** includes common JPEG, HEIC, TIFF, and camera RAW formats.
6. Save the job. Enable **Run automatically** or use **Sync Now**.

The menu-bar panel provides start/stop controls, status, one-click sync, and a per-job quick filter. The settings window contains the full job editor.

## Synchronization behavior

One-way jobs copy files that are missing or newer at the destination. Two-way jobs copy unique files in both directions and use the newer modification date when both sides contain a path. If timestamps are effectively equal but sizes differ, the app refuses to overwrite either file because the correct version is ambiguous.

Version 2.0 intentionally does not mirror deletions. A temporary network outage, empty server listing, or accidental source-folder change therefore cannot erase newsroom files.

Local files are copied to a hidden staging file in the destination directory and then moved into place. Remote transfers use a private temporary file. File names are never rewritten.

## Protocol notes

- **FTP:** Supported for compatibility, but credentials and files are unencrypted. The app warns when it is selected.
- **FTPS:** Implicit TLS with system certificate validation, normally on port 990.
- **SFTP:** Password authentication over SSH. The first observed host key is stored locally. If it changes, the connection is refused until the user explicitly forgets the trusted key in the job editor.
- **Local:** Folder access is persisted with a security-scoped bookmark and restored on launch.

## Architecture

The sync engine works against a small endpoint-session protocol, keeping scheduling and conflict rules independent of transport details. FTP/FTPS is implemented with Apple’s Network framework. SFTP uses the pinned [Citadel 0.12.1](https://github.com/orlandos-nl/Citadel) Swift package. Citadel is the only direct third-party dependency.

Jobs are stored as readable JSON under the app’s Application Support container. Secrets are referenced by random credential IDs and live only in Keychain.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
