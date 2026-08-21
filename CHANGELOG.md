# Changelog

## 2.0.0 — 2026-08-21

- Rebuilt the application as a native SwiftUI menu-bar utility.
- Added configurable FTP, FTPS, SFTP, and local endpoints.
- Added multiple concurrent sync jobs and per-job schedules.
- Added upload, download, two-way, and local-to-local synchronization.
- Added JPEG, RAW, photo, video, all-file, and custom extension filters.
- Added recent-file filtering for fast newsroom workflows.
- Added Keychain credentials and durable security-scoped folder bookmarks.
- Fixed local folder selection so sandbox permission bookmarks are captured and shown reliably.
- Added optional age-based cleanup for matching files in a one-way job's local target.
- Added validation that cleanup is older than the source sync window and can never run against a source, remote target, two-way job, or overlapping local folder.
- Added atomic local writes, metadata preservation, path validation, TLS validation, and SSH host-key pinning.
- Removed the bundled rclone executable.
- Added unit and local integration tests.
