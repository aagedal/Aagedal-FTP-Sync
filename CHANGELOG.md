# Changelog

## Unreleased

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
