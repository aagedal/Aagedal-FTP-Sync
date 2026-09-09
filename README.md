# Aagedal FTP Sync 2.9

A native macOS menu-bar utility for getting newsroom files where they need to go quickly. It is designed for photojournalists who deliver directly from a camera to a server and for picture desks that need the newest JPEG and RAW files within seconds.

Version 2.9 adds optional metadata calendar sharing through a user-configured HTTPS PHP/MySQL server, with whole-calendar or date-range sharing, multiple editors, offline edits and explicit conflict resolution. Manual `.aftpsync` imports now retain overlapping metadata clips and show a warning. The app has no hard-coded server and does not bundle rclone.

## What is new

- Any number of independent sync jobs
- Local folders, FTP, implicit FTPS, and SFTP endpoints
- Remote → local, local → remote, and two-way synchronization
- Local → local and two-way local folder synchronization
- Per-job schedules from 2 seconds to 5 minutes
- Quick filters for JPEG, camera RAW, all photos, video, all files, or custom extensions
- Optional recent-file windows for busy assignment folders
- Per-job photographer-initial filters and filename prefix/suffix exclusions
- Optional upload prefixes and suffixes, preserving local filenames and RAW/XMP pairing
- Optional age-based cleanup of matching files in a one-way job's local target
- Original filenames and modification dates are preserved when the server supports it
- Choose source modification time or local download time for downloaded files and processed copies
- Optional SHA-256 comparison detects changed contents even when file size and modification date still match
- Passwords are kept in macOS Keychain, never in the jobs file
- Named FTP, FTPS, and SFTP server profiles can be reused by jobs with independent remote paths
- Automatic jobs that reference a recovered remote server profile remain paused until the connection settings are reviewed
- Security-scoped folder bookmarks survive sandboxed app restarts
- SFTP host keys require explicit SHA-256 fingerprint verification; unexpected changes are rejected
- SFTP operations have inactivity deadlines and release stalled or cancelled channels promptly
- FTPS certificates use normal system trust validation
- New files are staged before atomic local replacement
- Remote path traversal and symbolic-link traversal are rejected
- Source deletions are never propagated
- Download resets remove only files recorded in the job's durable ownership manifest
- A shared photographer library and per-job timeline clips can apply Headline, Description, Keywords, Creator, and Copyright metadata automatically
- Photographer tracks are specific to each programming day, and clips can be dragged between tracks
- The Photographer Map includes a compact per-photographer schedule and frames every clip location for the selected day
- Each photographer can have multiple comma-separated filename initials for assignments using more than one camera
- Scheduling can use source modification, local arrival, or Exif camera-capture time
- Existing fields can be preserved or overwritten, while camera RAW files receive XMP sidecars without changing the original RAW data
- A read-only local-folder preview, separate metadata outcome counts, and a per-file audit trail make automation decisions inspectable
- Indexed, recoverable source signatures and atomic recovery keep rewritten destinations verifiable and safe when metadata processing fails
- Successfully tagged files can use a custom processed folder or a managed main folder containing sibling `Synced Files` and `Processed Files` folders
- Processed pictures can optionally be sorted into sanitized `Photographer Name (INITIALS)` sub-folders while preserving their source-relative paths
- Sync jobs, their referenced server profiles, and metadata programming can be exported separately or together in `.aftpsync` packages, with password protection enabled by default

## Optional metadata calendar sync

Calendar sharing uses a user-configured HTTPS PHP/MySQL server: whole calendars or selected dates, editor/read-only invitations, offline edits and explicit conflict resolution. Configure it under **Settings → Metadata Sync**. FTP credentials and local processing policies remain private to each Mac. See the [server installation and behavior guide](Server/MetadataSync/README.md) for deployment steps, date-range boundaries, limits and deployment verification.

Saved metadata edits sync after a short pause in editing. Updates from other Macs are checked about every ten seconds while the app is open, even with automatic file transfers disabled. Open drafts pause calendar updates until saved or closed. The metadata window shows changes waiting to sync, connection failures, and the last successful sync; **Retry Now** requests another attempt. Saved offline edits stay on this Mac and sync automatically when the server becomes reachable. Requests made during another calendar operation are queued.

## Modification times and watched folders

For a one-way job with a local destination, choose **Safety → File modification time → Download time** to sort downloaded files by local arrival. **Source modification time** is the default. This is the same saved setting as the earlier **Preserve modification dates** toggle (off means download time), and applies to new downloads, replacements, and processed copies. Dates change when files are downloaded or replaced; there is no separate retimestamping pass. Source signatures track later resends even when the local download date is newer than the source date; older downloads without a saved signature may be downloaded once to establish that history.

Files are downloaded and metadata is written in temporary storage. Local publication sets the final filesystem modification time on a hidden staging file before moving or replacing the final filename. It does not subsequently touch the visible file to change its date. Camera capture dates and embedded EXIF/XMP dates are separate from this filesystem timestamp and are not rewritten by this setting.

Adobe Bridge maintains its own [thumbnail and metadata cache](https://helpx.adobe.com/ro/bridge/using/centrally-manage-bridge-cache.html). If the displayed modification date and sorting order disagree, compare the filesystem modification date in Finder with Bridge's date, confirm **Date Modified** sorting, and refresh the folder view. Record whether a refresh or clearing that folder's Bridge cache fixes the order. A correct filesystem timestamp alone cannot force another application's cached view to re-sort. See the [timestamp investigation](Documentation/Modification-Time-Investigation.md) for verification results and a focused reproduction checklist.

## Requirements

- An Apple silicon Mac running macOS 14 Sonoma or newer
- Xcode 16 or newer to build
- An FTP server with passive mode and `MLSD` or Unix-style `LIST` support
- Implicit FTPS normally uses port 990. Use SFTP when available.

## Build

Open `Aagedal FTP Sync.xcodeproj` and select the `AagedalFTPSync` scheme. For signed builds, create `Configuration/Signing.local.xcconfig` with your own `DEVELOPMENT_TEAM = YOUR_TEAM_ID`, or pass that setting to `xcodebuild`. This optional file is ignored by Git; account-specific signing settings do not belong in the shared project. Then build and run.

The committed Xcode project is generated from [`project.yml`](project.yml) with [XcodeGen](https://github.com/yonaskolb/XcodeGen). Regenerate it after changing project structure:

```sh
xcodegen generate
```

Run the test suite:

```sh
xcodebuild test \
  -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Run the isolated macOS UI smoke suite with a configured development signing identity:

```sh
xcodebuild test \
  -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSyncUISmokeTests \
  -destination 'platform=macOS'
```

UI automation requires a signed test runner, so do not add `CODE_SIGNING_ALLOWED=NO` to this command.

The scheduled integration workflow runs this suite on a trusted self-hosted macOS runner with an Apple Development identity. Give that runner the custom `signed-ui-tests` label and configure the repository variable `APPLE_DEVELOPMENT_TEAM` for its signing account; pull-request events never automatically dispatch code to it.

Opt-in loopback FTP, trusted implicit-FTPS, and SFTP write/fault tests use OpenSSL plus the pinned Python packages in `Scripts/delivery-latency-requirements.txt`. Install the Python packages in an activated virtual environment, then run:

```sh
Scripts/run-remote-transport-tests.py
```

The same loopback suite runs weekly in scheduled CI and can be started manually from the Actions page. Set `AFTPSYNC_TEST_DERIVED_DATA` to a reusable build directory to speed up local reruns; the server folders and credentials remain disposable for each run.

## First setup

1. Click the sync icon in the menu bar.
2. Choose **Create Sync Job**.
3. Configure the left and right endpoints and choose a direction.
4. For local endpoints, use **Choose…** so macOS can grant durable folder access.
5. For SFTP, test the connection, independently verify the displayed `SHA256:` host-key fingerprint with the server administrator, and choose **Trust Verified Fingerprint**.
6. Pick a quick file filter. **All photos** includes common JPEG, HEIC, TIFF, and camera RAW formats.
7. Save the job. Enable **Run automatically** or use **Sync Now**.

The menu-bar panel provides start/stop controls, status, one-click sync, and a per-job quick filter. The settings window contains the full job editor.

## Synchronization behavior

For a shared convention across app users, enable **Upload filenames → Add standard _aftpsync suffix**. `TA_001.JPG` becomes `TA_001_aftpsync.JPG`; with a custom `_EDITED` suffix, it becomes `TA_001_EDITED_aftpsync.JPG`. Local names stay unchanged, and RAW/XMP companions share the marker. A marker already at the end of the resulting filename stem is not duplicated. On download jobs, enable **File filter → Ignore _aftpsync uploads** to skip marked files from any user, ignoring capitalization. Both options are off by default, including for existing jobs.

Under **File filter**, enter comma-separated **Photographer initials** to sync only filenames that start with one of those initials, matching the photographer library's prefix convention. Leave this blank for all photographers. **Ignore filename prefixes** and **Ignore filename suffixes** exclude matching names, even if their initials match. All these rules ignore capitalization and apply to the filename, not its folders. Suffixes match the stem before the extension. Type, hidden-file, and age filters still apply; filename rules also limit local cleanup and metadata reprocessing.

To download and upload using the same server folder, use two one-way jobs. For example, set the download job's initials to `TA, JAD` and its ignored suffixes to `_EDITED`. On the local-to-server job, set **Upload suffix** to `_EDITED`: `TA_001.JPG` uploads as `TA_001_EDITED.JPG`, and the download job ignores that returned copy. An upload prefix such as `EDITED_` can be used with the corresponding download prefix exclusion instead, or both can be combined. Initials alone do not exclude uploads that still start with those initials. These exclusions are configured on the download job; upload naming does not modify other jobs automatically.

Upload naming preserves folders, extension capitalization, and local source names. RAW files and XMP companions receive matching names. Repeat runs compare against the renamed server paths, and source filename filters run before the upload name is added. Naming is restricted to one-way local-to-server jobs; changing a prefix or suffix creates a new server name and leaves previously uploaded copies in place. Unsafe, reserved, and oversized output names are rejected before upload.

One-way jobs also check a selected RAW file's existing XMP companion for changes, even when the extension filter excludes standalone XMP files. A missing or changed companion transfers with its RAW as one output group. When automatic metadata rewrites the destination XMP, saved source signatures distinguish source edits from the app's own metadata changes.

One-way FTP, FTPS and SFTP downloads automatically give case-colliding filenames distinct local names, so files such as `PHOTO.JPG` and `PHOTO.jpg` can both be downloaded to a Mac. A renamed file receives a stable suffix before its extension, such as `PHOTO~a1b2c3d4e5.jpg`. The app remembers the association for future updates and leaves server names intact. An existing local file keeps its name; new colliding downloads receive a suffix. Under the job’s **Safety** settings, enable **Overwrite repeated filenames with different capitalization** to select the newest server variant and reuse one local filename instead. Timestamp ties use a consistent filename order. The option defaults off, and enabling it does not delete previously renamed copies. Keep the app’s local download-name records when migrating its data. Directory collisions and ambiguous RAW/XMP companion names still require a manual rename; automatic renaming applies to one-way remote-to-local downloads.

If a source file exceeds its listed size during download, or the completed download is shorter than expected, the app discards the staged copy and defers that file until the next sync reads a fresh directory listing. Other transfers continue, and the job shows a warning instead of treating the changing file as a failed run. Existing local copies remain available. A changing RAW or XMP defers the whole pair. Automatic jobs retry at their normal interval; manual jobs retry when run again. This can happen while a sender is still uploading or replacing a file. Size checks detect changes, but cannot prove an upload has finished if it pauses at a stable size.

One-way jobs copy files that are missing or newer at the destination. Two-way jobs copy unique files in both directions and use the newer modification date when both sides contain a path. If timestamps are effectively equal but sizes differ, the app reports a conflict and refuses to overwrite either file because the correct version is ambiguous. Jobs can optionally download equal-size, equal-timestamp files and compare SHA-256 checksums. A one-way mismatch refreshes the destination; a two-way mismatch is reported as a conflict. This mode is intentionally off by default because it reads both copies and can add substantial remote transfer time.

The app runs at most two sync or metadata-reprocessing operations at once and admits only one operation at a time for the same normalized remote host and port. Jobs waiting for capacity remain cancellable, and each admitted job still lists its own endpoints concurrently.

For one-way syncs from FTP or FTPS, a download timeout or file-unavailable reply triggers a fresh connection and a check of the file's parent folder. If a complete, recognized listing no longer contains the file, the app continues with the remaining files and reports the missed paths at the end of the run. Otherwise, if the folder check succeeds, the failed file moves behind the other files for one retry on a fresh connection. Each file group gets at most two attempts per run, including early downloads and failed content comparisons. Unresolved errors remain in the run report; partial file groups are never published. When these individual source failures are the only problem, automatic jobs keep their normal polling interval. If the folder cannot be checked, the original failure still stops the run. This tolerates server cleanup races but cannot recover a file deleted before it was downloaded.

Version 2.0 intentionally does not mirror source deletions. A temporary network outage, empty server listing, or accidental source-folder change therefore cannot erase newsroom files.

For one-way jobs with automatic metadata, processed-file handoff can be enabled explicitly. Custom Folder mode keeps the existing independently selected local processed folder. Processed sub-folder mode treats the selected local destination as a managed main folder and creates sibling `Synced Files` and `Processed Files` roots, ensuring processed copies are never enumerated as ordinary downloads. Processed pictures can optionally receive a readable `Photographer Name (INITIALS)` folder above their preserved source-relative path; a short stable identifier is added only when sanitized names and initials would otherwise collide. The app removes the original from the source only after the synced copy, metadata-written processed copy, and any RAW XMP sidecar are verified. Before deletion, it stages the source files and compares their contents with the original downloads; changed files are restored. For remote sources, this safety check reads the staged files from the server again. Metadata skips, failures, and processed-file collisions leave the source untouched.

For one-way jobs with a local target, you can optionally remove matching target files after a chosen age. Cleanup requires a recent-file source window, and its deletion age must be longer than that window—for example, sync files from the last hour and remove matching target files older than two hours. A camera RAW file and its existing or generated XMP sidecar are treated as one output group: every member must still match the expected type and age immediately before removal, and a failed group deletion restores the pair when possible. The app evaluates only target entries and never issues a cleanup delete operation to the source. Cleanup is unavailable for two-way jobs, remote targets, and overlapping local folders.

Local source and destination folders must be separate: identical folders and folders nested inside one another are rejected. Local files are copied to a hidden staging file in the destination directory and then moved into place. Remote uploads use a private sibling file, optionally verify its uploaded size, and publish it by rename with rollback protection for servers that cannot replace an existing path directly. Upload names are preserved unless an upload prefix or suffix is configured.

## Protocol notes

- **FTP:** Supported for compatibility, but credentials and files are unencrypted. The app warns when it is selected.
- **FTPS:** Implicit TLS with system certificate validation, normally on port 990.
- **SFTP:** Password authentication over SSH. A job cannot be saved until the user explicitly verifies and trusts the server's SHA-256 host-key fingerprint. A changed key is always refused and both expected and received fingerprints are shown for investigation.
- **Local:** Folder access is persisted with a security-scoped bookmark and restored on launch.

## Architecture

The sync engine works against a small endpoint-session protocol, keeping scheduling and conflict rules independent of transport details. FTP/FTPS is implemented with Apple’s Network framework. SFTP uses a security-patched local baseline of [Citadel 0.12.1](https://github.com/orlandos-nl/Citadel); its provenance and local changes are documented in [`Vendor/README.md`](Vendor/README.md). Editorial metadata is read and written with [SwiftMediaMetadata](https://github.com/aagedal/SwiftMediaMetadata).

Dependency security and release verification are documented in [`SECURITY.md`](SECURITY.md).

Jobs are stored as readable JSON under the app’s Application Support container. Secrets are referenced by random credential IDs and live only in Keychain.

Portable `.aftpsync` packages never contain Keychain passwords or security-scoped folder bookmarks. Referenced server profiles are included with fresh profile and credential identifiers so shared connections remain intact without exposing passwords. Password protection is enabled by default and uses PBKDF2-HMAC-SHA256 with AES-256-GCM authenticated encryption, but it can be turned off for non-sensitive transfers. Unencrypted packages expose server addresses, usernames, paths, and metadata programming to anyone who can read the file. Imported jobs are disabled and receive fresh identifiers, so folder permissions and server passwords must be configured again before syncing.

Manual `.aftpsync` imports preserve overlapping metadata clips and report a warning in the import summary, including overlaps with retained local clips. Other malformed metadata still blocks import. This exception applies only to manual import; normal calendar validation and live-sync conflict checks are unchanged.


## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
