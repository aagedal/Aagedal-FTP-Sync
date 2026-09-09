# Modification times and Adobe Bridge sorting

Investigated on 2026-09-09. The reported Adobe Bridge sorting problem has not been reproduced in Bridge itself. Two app-side inconsistencies were reproduced with regression tests and corrected; neither establishes the cause of a Bridge view showing the right date in its metadata panel but the wrong sorting position.

## Confirmed findings

- The existing `preserveModificationDates` job preference already supports local download time when false. The editor now presents **Safety → File modification time → Source modification time / Download time** for one-way local destinations. The persisted key and default stay the same.
- Processed-folder publication hard-coded timestamp preservation. JPEG, RAW, and generated XMP processed copies therefore retained the source date even with download time selected. Publication now passes the job's preference to processed copies.
- Ordinary one-way downloads could skip resends whose source modification time was newer than the previous source version but older than the local download time. These jobs now persist and compare source signatures, including early downloads and source XMP companions. The comparison is independent of file-size verification. A preexisting destination with no receipt is downloaded once to establish source history; unchanged sources then remain untouched.
- Metadata reprocessing intentionally preserves the existing local modification date. Download-time changes occur during publication, including any one-time download needed to establish a missing source receipt.

## Publication and notification checks

`SyncEngine` completes downloading and metadata writing in temporary storage. `LocalEndpointSession` copies the result into a hidden `.aagedal-sync-*.part` file in the destination directory, verifies its size when enabled, and sets its final filesystem modification date before moving or replacing the final filename. Early publication and processed copies follow the same staging-before-publication ordering. There is no post-publication timestamp correction.

A separate local stress probe performed 1,000 Foundation `replaceItemAt` replacements while a `kqueue` directory watcher observed 2,997 notifications. Every observed timestamp belonged to the old or replacement file; no transient incorrect date or missing destination was observed. This checks macOS filesystem behavior on this machine, not Bridge's cache behavior or every filesystem.

Regression coverage in `LocalSyncIntegrationTests` checks directory notifications for both new files and replacements using preserved dates and download time. It also checks processed JPEG/RAW/XMP dates and same-size resends with file-size verification on and off. `DownloadNamingTests` checks receipt persistence across a restarted engine after early remote publication, including a resend only one second newer than its previous source version.

The full `AagedalFTPSync` test suite passed: 461 passed, 15 opt-in tests skipped, zero failures. The skips cover optional transport/benchmark fixtures; no Bridge UI test was run.

## Focused Bridge reproduction

Use a disposable source and destination and keep Bridge open on the actual folder being monitored:

1. Sort by **Date Modified**, descending. Confirm this is the active sort criterion, rather than capture date, creation date, or manual order. Adobe documents sorting through the [Sort control or List-view column headers](https://helpx.adobe.com/bridge/desktop/organize-and-find-files/organize-files-and-folders/sort-and-filter-files-and-folders.html).
2. With **Source modification time**, deliver several photos whose source dates have a known order. Include a replacement at an existing filename and a RAW/XMP pair. Record Bridge's order immediately after arrival and after refreshing the folder view.
3. Repeat with **Download time** and new filenames. Check the download folder and any configured processed folder. Files should have the local time at which each copy was saved, regardless of camera capture time.
4. For a misplaced file, compare Finder's **Date Modified** with Bridge's displayed date and its sort position. Embedded EXIF/XMP dates are distinct from the filesystem modification time; this setting does not synchronize those metadata fields.
5. If refreshing or reselecting the sort fixes the order, record that outcome. If needed, clear only the affected test folder's Bridge cache and retry. Bridge's [cache stores thumbnail and metadata information](https://helpx.adobe.com/ro/bridge/using/centrally-manage-bridge-cache.html), so stale cached ordering remains a possibility even with correct filesystem timestamps.

Record the Bridge version, macOS version, destination filesystem or network mount, timestamp setting, whether files are new or replacements, whether metadata/processed folders are enabled, and whether refresh/cache clearing fixes the order. A filesystem notification cannot guarantee that another application's cached list will re-sort.
