# Changelog

## Unreleased

- Back off automatic calendar-sync retries after connection failures, skip redundant requests to the same unavailable account, and retain immediate manual Retry Now. Refresh the calendar picker less often without slowing healthy linked-calendar updates.
- Avoid duplicate network-failure diagnostic entries and explain connection error codes without exposing addresses or credentials.

## 2.9.2 — 2026-09-09

- Sync saved metadata edits after a short pause in editing instead of waiting for the next polling cycle. Resume when drafts are saved or closed, and queue refresh requests made while another calendar operation is running.
- Distinguish saved changes waiting to sync from connection failures, retain the last successful sync time, and offer Retry Now when the server cannot be reached.
- Add regression coverage for rapid edits, open drafts, offline recovery, queued refreshes, and edits saved during an upload. Keep local processing preferences out of calendar sync requests.
- Show an explicit source modification time/download time choice for local downloads, retaining existing job preferences.
- Apply the job's modification-time choice to processed JPEG, RAW, and XMP copies as well as downloads.
- Track source signatures for download-time jobs so a newer local date does not hide subsequent same-name deliveries or sidecar updates. Existing copies without a receipt may be downloaded once to establish source history.
- Verify that folder watchers see finalized modification times for new files and replacements, and document Adobe Bridge sorting diagnostics.

## 2.9.1 — 2026-09-09

- Add an optional standardized `_aftpsync` upload suffix and a matching filename-filter toggle for shared-server workflows. Both default off and preserve existing job behavior.
- Add case-insensitive photographer-initial filters and filename prefix/suffix exclusions, including filtering ignored downloads before case-collision naming.
- Add optional prefixes and suffixes for one-way uploads, keeping local names, RAW/XMP companions, and repeat-run comparisons consistent. Use matching download exclusions when returning edited files to the same server.
- Detect source XMP companion updates in one-way photo/RAW jobs even when the RAW itself is unchanged; retain source receipts when automatic metadata rewrites XMP to prevent repeated transfers.
- Extend FTP, FTPS, and SFTP integration coverage with a shared-server download/upload cycle and rejected-upload size verification.

- Defer source files whose size changes during download until the next sync obtains a fresh listing, while continuing other transfers and showing a waiting warning. Keep strict size limits, existing destination copies, and RAW/XMP groups intact.

- Add an optional per-job setting to overwrite repeated downloads whose names differ only by capitalization, selecting the newest server variant and retaining one local filename. Existing jobs continue to preserve both copies.
- Automatically give case-colliding files distinct, remembered local names during one-way FTP/FTPS/SFTP downloads. Preserve both files and original server names, including across retries and restarts. Ambiguous RAW/XMP companions and colliding directories retain their safety checks.

## 2.9.0 — 2026-09-09

- Share metadata calendars or selected dates through a user-configured HTTPS PHP/MySQL server, with editor/read-only invitations, automatic polling, offline edits and explicit conflict resolution.
- Open calendar sharing from Metadata Timeline. Receive into a chosen local job, with an option to duplicate populated jobs while preserving the original programming and disabling automatic running and launch startup on both jobs.
- Simplify calendar setup with a single Activate Sync action for new or existing shared calendars, support for pasting a complete invitation, and a clear note about the approximately ten-second sync interval. After receiving, select the linked job in the Metadata window.
- Show per-job calendar sync status, fetching/sending activity, last successful sync, manual retry and saved diagnostic history directly from the Metadata window.
- Save pending metadata clip deletions before switching jobs. Deleting the last clip disables automatic metadata processing so the empty calendar can be saved; failed saves retain the current draft, and undo restores the prior processing setting.
- Merge independent clip and field edits automatically. Resolve competing edits or deletion-versus-edit conflicts per clip while keeping unrelated changes; review overlapping schedules together and reject stale resolutions if the calendar changes again.
- Preserve local programming and pause sync if a calendar's shared date range or time zone changes, or the server returns an older revision after a backup restore.
- Allow manual `.aftpsync` imports containing overlapping metadata clips, keeping the clips and showing a warning. Live calendar sync and normal schedule validation retain their overlap checks.
- Run the disposable PHP/MySQL calendar integration suite in release CI.

## 2.8.1 — 2026-09-08

- Reject duplicate server listings without crashing, wait for cancelled listings before closing their sessions, and prevent SFTP root validation from restoring stale connection state.
- Preserve reset recovery files when rollback fails, and redact passwords from malformed FTP replies in error history.

- Clear clip highlighting when keyboard playhead navigation lands in empty timeline space; select only the clip containing the playhead.

- Make Photographer Map marker dragging follow the pointer directly, with a fixed pin-center anchor and map navigation suspended during a marker move.

- Merge imported metadata programming by clip UUID: update matching clips, add new clips, and retain local clips omitted from an export. Incoming versions win; overlapping assignments are rejected before saving.
- Preserve full clip durations and stable identities in selected-day exports, including overnight assignments.

- Verify staged source contents against the original download before processed-file removal, restoring changed files and their companions instead of deleting them.
- Retain recovery backups and report their locations when destination rollback fails.
- Reject overlapping source and destination folders for ordinary local sync jobs to prevent recursive copying.

## 2.8.0 — 2026-09-04

### Safer unattended operation

- Pause automatic jobs whose FTP, FTPS, or SFTP profile was recovered from backup until its connection settings have been reviewed.
- Bound SFTP file operations with inactivity deadlines and promptly close stalled or cancelled channels while retaining actionable timeout history.
- Reset ordinary download destinations using a durable ownership manifest, preserving unrelated files and recoverable state when deletion fails.
- Move source-signature history into an indexed, recoverable SQLite database with conservative retention and pruning.

### Improved Photographer Map

- Make photographer tracks specific to each programming day and automatically carry a track forward when a clip extends past midnight.
- Move metadata clips directly between photographer tracks by dragging them vertically.
- Replace the Photographer Map time slider with a responsive, compact per-photographer schedule overview that distinguishes clips with and without locations, supports direct selection, and opens clips in Metadata Programming on double-click.
- Fit the map to every clip location for the selected day.

### Accessibility and release confidence

- Improve VoiceOver and keyboard access with explicit descriptions for image-only actions, arrow-key Photographer Map timeline scrubbing, and an English localization catalog.
- Keep timelines, menu-bar controls, configuration sheets, and status messages legible and operable at accessibility text sizes without relying on color alone.
- Target Apple silicon Macs with an arm64-only application build.
- Add release-identity validation, scheduled FTP/FTPS/SFTP integration tests, and signed UI smoke coverage on a trusted runner.

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
