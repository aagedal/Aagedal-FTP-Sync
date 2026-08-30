# Aagedal FTP Sync 2.5

A native macOS menu-bar utility for getting newsroom files where they need to go quickly. It is designed for photojournalists who deliver directly from a camera to a server and for picture desks that need the newest JPEG and RAW files within seconds.

Version 2.5 builds automatic editorial metadata programming on the clean SwiftUI rewrite. It has no hard-coded server and does not bundle rclone.

## What is new

- Any number of independent sync jobs
- Local folders, FTP, implicit FTPS, and SFTP endpoints
- Remote → local, local → remote, and two-way synchronization
- Local → local and two-way local folder synchronization
- Per-job schedules from 2 seconds to 5 minutes
- Quick filters for JPEG, camera RAW, all photos, video, all files, or custom extensions
- Optional recent-file windows for busy assignment folders
- Optional age-based cleanup of matching files in a one-way job's local target
- Original filenames and modification dates are preserved when the server supports it
- Passwords are kept in macOS Keychain, never in the jobs file
- Security-scoped folder bookmarks survive sandboxed app restarts
- SFTP host keys are pinned on first use; unexpected changes are rejected
- FTPS certificates use normal system trust validation
- New files are staged before atomic local replacement
- Remote path traversal and symbolic-link traversal are rejected
- Source deletions are never propagated
- A shared photographer library and per-job timeline clips can apply Headline, Description, Keywords, Creator, and Copyright metadata automatically
- Each photographer can have multiple comma-separated filename initials for assignments using more than one camera
- Scheduling can use source modification, local arrival, or Exif camera-capture time
- Existing fields can be preserved or overwritten, while camera RAW files receive XMP sidecars without changing the original RAW data
- A read-only local-folder preview, separate metadata outcome counts, and a per-file audit trail make automation decisions inspectable
- Original source signatures and atomic recovery keep rewritten destinations verifiable and safe when metadata processing fails
- An optional per-job processed folder can receive successfully tagged files before their originals are removed from local, FTP, FTPS, or SFTP sources

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

One-way jobs copy files that are missing or newer at the destination. Two-way jobs copy unique files in both directions and use the newer modification date when both sides contain a path. If timestamps are effectively equal but sizes differ, the app reports a conflict and refuses to overwrite either file because the correct version is ambiguous.

Version 2.0 intentionally does not mirror source deletions. A temporary network outage, empty server listing, or accidental source-folder change therefore cannot erase newsroom files.

For one-way jobs with automatic metadata, a per-job local processed folder can be enabled explicitly. The app first writes and verifies the destination, then places the metadata-written file—and an XMP companion for RAW—into the processed folder. Only after both copies succeed does it remove the original from the source. Metadata skips, metadata failures, and processed-folder collisions leave the source untouched. The processed folder must be separate from local source and destination folders.

For one-way jobs with a local target, you can optionally remove matching target files after a chosen age. Cleanup requires a recent-file source window, and its deletion age must be longer than that window—for example, sync files from the last hour and remove matching target files older than two hours. The app evaluates only target entries for deletion, re-checks each file's type and modification date immediately before removal, and never issues a delete operation to the source. Cleanup is unavailable for two-way jobs, remote targets, and overlapping local folders.

Local files are copied to a hidden staging file in the destination directory and then moved into place. Remote uploads use a private sibling file, optionally verify its uploaded size, and publish it by rename with rollback protection for servers that cannot replace an existing path directly. File names are never rewritten.

## Protocol notes

- **FTP:** Supported for compatibility, but credentials and files are unencrypted. The app warns when it is selected.
- **FTPS:** Implicit TLS with system certificate validation, normally on port 990.
- **SFTP:** Password authentication over SSH. The first observed host key is stored locally. If it changes, the connection is refused until the user explicitly forgets the trusted key in the job editor.
- **Local:** Folder access is persisted with a security-scoped bookmark and restored on launch.

## Architecture

The sync engine works against a small endpoint-session protocol, keeping scheduling and conflict rules independent of transport details. FTP/FTPS is implemented with Apple’s Network framework. SFTP uses the pinned [Citadel 0.12.1](https://github.com/orlandos-nl/Citadel) Swift package, and editorial metadata is read and written with [SwiftExif](https://github.com/aagedal/SwiftExif).

Jobs are stored as readable JSON under the app’s Application Support container. Secrets are referenced by random credential IDs and live only in Keychain.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
