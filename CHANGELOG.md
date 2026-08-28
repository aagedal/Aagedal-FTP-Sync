# Changelog

## Unreleased

- Start the 2.5 metadata workflow with per-job photographer profiles, filename-prefix matching, scheduled day clips, and SwiftExif-powered IPTC/XMP writing for files synced to local folders.
- Add a dedicated metadata-programming window with a calendar, photographer library, visual day tracks, cross-day confirmation, and clip copying between photographers.
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
