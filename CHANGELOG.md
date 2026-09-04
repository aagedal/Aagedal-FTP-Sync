# Changelog

## Unreleased

- Make photographer tracks specific to each programming day and automatically carry a track forward when a clip extends past midnight.
- Move metadata clips directly between photographer tracks by dragging them vertically.
- Replace the Photographer Map time slider with a compact per-photographer schedule overview that distinguishes clips with and without locations, supports direct selection, and opens clips in Metadata Programming on double-click.
- Pause jobs that use server profiles restored from backup until their connection settings have been reviewed.

## 2.7.1 — 2026-09-03

- Remove the duplicate photographer name shown beneath each marker in the Photographer Map.

## 2.7.0 – 2026-09-03
### Faster, more dependable syncing
- Eligible new files can begin transferring before a large remote folder has finished scanning.
- Optional content verification detects changed files even when their size and modification date are identical.
- Completed transfers remain visible if a later part of the sync fails.
- Safer publishing and rollback prevent partially copied files or RAW/XMP pairs from being left behind.
- Shared limits keep simultaneous jobs from overwhelming the same server.

### Reusable server profiles
- Save FTP, FTPS, and SFTP connections as named server profiles.
- Reuse one server across multiple jobs while giving each job its own remote folder.
- See which jobs use a server before editing or deleting it.
- Duplicate a profile when you need separate credentials or trust settings.
- Existing remote connections are migrated automatically while preserving Keychain credentials.

### Improved metadata programming
- Add an optional GPS location to timeline clips and write it to image metadata or RAW XMP sidecars.
- View photographers’ scheduled positions in the new Photographer Map, with date selection and a time scrubber.
- Copy and paste a day’s programming, or Option-drag clips to duplicate them.
- Export programming for a specific day and import programming directly into a selected job.
- Reprocess matching files for an entire job, one photographer, or a single timeline clip.
- Photographer settings now autosave and provide clearer validation.
- Improved timeline layout, keyboard accessibility, navigation, and window focus behavior.

### Safer configuration transfer
- Export sync jobs, metadata programming, or both in a single .aftpsync package.
- Packages are password-protected by default.
- Keychain passwords and machine-specific folder permissions are never exported.
- Imported jobs receive new identities and start disabled, allowing folders and passwords to be reviewed before syncing.

### Clearer failure reporting
- The menu-bar icon now distinguishes failures and warnings.
- Throttled macOS notifications highlight failures that need attention.
- Sync failure history preserves useful partial-progress information.
- Export a privacy-safe support bundle containing recent diagnostics without filenames, paths, server details, credentials, or raw error messages.

### Additional improvements
- RAW files and their XMP companions are treated as one recoverable group during cleanup.
- Unsaved job changes are protected when switching jobs or closing the window.
- New jobs remain drafts until successfully saved.
- Photographer-sorted output folders use readable names such as Photographer Name (INITIALS), with safe disambiguation when names collide.
- Refined menu-bar controls and quicker access to common job actions.
- Expanded automated coverage for FTP, FTPS, SFTP, security checks, configuration transfer, and core user workflows.


## 2.6.0 — 2026-08-30

- Add Custom Folder and Processed sub-folder modes for processed-file handoff.
- Add a managed main-folder layout with isolated `Synced Files` and `Processed Files` sibling roots.
- Optionally sort processed pictures into safe per-photographer sub-folders while retaining source-relative paths and RAW sidecars.
- Patch the transitive SwiftNIO SSH memory-corruption vulnerability CVE-2026-43798 and add its upstream regression coverage.
- Upgrade Swift Crypto to 4.5.1 to address CVE-2026-43823.
- Require explicit verification and approval of SFTP `SHA256:` host-key fingerprints before a job can be saved or credentials accepted.
- Bound FTP/FTPS reply lines, multiline replies, and directory listings, with inactivity timeouts for network reads and writes.
- Add a documented vendored-dependency baseline and a regression guard script.

## 2.5.0

- Start the 2.5 metadata workflow with per-job photographer profiles, filename-prefix matching, scheduled day clips, and SwiftExif-powered IPTC/XMP writing for files synced to local folders.
- Add a dedicated metadata-programming window with a calendar, photographer library, visual day tracks, cross-day confirmation, and clip copying between photographers.
- Replace the compact system calendar with a full-width month grid that highlights programmed days and keeps month and today navigation close at hand.
- Keep photographer profiles in a backup-protected library shared across sessions and sync jobs, with quick reuse from the metadata programmer.
- Support comma-separated filename initials so one photographer can use multiple cameras with different filename prefixes.
- Add per-job photographer reordering, default and date-specific work-hour backgrounds with week-level editing, and a Settings window for managing shared photographer profiles.
- Leave unscheduled timeline periods empty instead of rendering orange gap overlays.
- Add direct timeline editing with configurable snapping, edge resizing, multi-clip copy/paste, schedule warnings, continuation markers, and keyboard navigation.
- Write programmed metadata to XMP sidecars for RAW photos, including DNG and CR3, while preserving the original camera files byte-for-byte.
- Add a reusable, backup-protected metadata preset library shared across jobs and days while keeping timeline clips as standalone snapshots.
- Add confirmed, on-demand reprocessing for matching files already in a local destination, preserving modification dates and generating RAW sidecars without rewriting camera files.
- Report metadata applied, skipped, and failed separately and retain a bounded, backup-protected per-file audit trail with photographer, clip, timestamp policy, diagnostic detail, and SwiftExif warnings.
- Add a read-only local-folder preview that evaluates an unsaved programming draft before automatic metadata is enabled.
- Make metadata preview and reprocessing idempotent by recognizing already-applied IPTC/XMP values and preserving existing non-empty fields without rewriting files.
- Add an opt-in local processed folder per job that receives successfully tagged files and RAW sidecars before originals are removed from local or remote sources.
- Persist original source signatures so equal-timestamp source changes remain detectable after embedded metadata changes destination size.
- Fall back to the untouched downloaded file when metadata writing fails, while recording the failure and preserving atomic destination replacement.
- Add JPEG, TIFF, DNG, CR3, HEIC, and XMP-sidecar round-trip and recovery coverage.
- Stage FTP, FTPS, and SFTP uploads under private names, verify their sizes when requested, and publish them by rename with rollback protection.
- Reject local destination paths that traverse symbolic links or collide by case or Unicode normalization.
- Keep automatic-sync failures visible and use exponential retry backoff up to five minutes.
- Report ambiguous two-way conflicts instead of silently presenting them as an empty successful run.
- Only show a successful save or start Sync Now after the job file has been committed.
- Back up valid job files and recover damaged primary files with recovered jobs paused for review.
- Remove orphaned Keychain credentials when an endpoint no longer uses them.

## 2.0.0 — 2026-08-21

- Rebuilt the application as a native SwiftUI menu-bar utility.
- Added configurable FTP, FTPS, SFTP, and local endpoints.
- Added multiple concurrent sync jobs and per-job schedules.
- Added upload, download, two-way, and local-to-local synchronization.
- Added JPEG, RAW, photo, video, all-file, and custom extension filters.
- Added recent-file filtering for fast newsroom workflows.
- Added a per-job option to show the latest sync session's transfer count instead of the cumulative count.
- Added Keychain credentials and durable security-scoped folder bookmarks.
- Fixed local folder selection so sandbox permission bookmarks are captured and shown reliably.
- Added optional age-based cleanup for matching files in a one-way job's local target.
- Added validation that cleanup is older than the source sync window and can never run against a source, remote target, two-way job, or overlapping local folder.
- Added atomic local writes, metadata preservation, path validation, TLS validation, and SSH host-key pinning.
- Removed the bundled rclone executable.
- Added unit and local integration tests.
