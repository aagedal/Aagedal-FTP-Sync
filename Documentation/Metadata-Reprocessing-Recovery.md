# Recovering interrupted metadata reprocessing

When a replacement cannot safely restore its originals, the error identifies a
hidden `.aagedal-sync-<UUID>.transaction` directory inside the destination folder
(inside `Synced Files` for managed jobs). Reset Job refuses to clear this recovery
state. Reprocessing also refuses to scan or write until retained reprocessing or
reset recovery folders have been resolved, including older folders without a
manifest. This avoids approving a partial listing when an original is still held
in recovery. Ordinary sync checks both local endpoints and any configured processed
folder before listing or early delivery begins. This prevents a resumed job from
filling missing paths or forwarding partial outputs before reconciliation, even
when metadata processing is disabled. The error identifies the folder to inspect. Stop the job and any
reprocessing before inspecting the folder. Keep a copy
of the complete recovery directory and the affected current destination files
until recovery is resolved.

New transactions contain `recovery.json`, written before any original is moved.
Its schema version is 1. Each `relativePath` is relative to the destination folder
containing the transaction directory. The manifest records:

- `originals`: the original path, its inspected `snapshotFilename`, its actual
  `heldFilename`, and whether the operation intended to replace it (`isReplaced`).
- `outputs`: the intended output path, its `stagedFilename`, expected output
  `snapshotFilename`, and possible `rollbackFilename`.

The manifest is a path map, not a completion record. Inspect which files actually
exist. Some originals may already have been restored and some outputs may already
have been published. An `original-held-*` file is the moved original; an
`original-copy-*` file is the earlier inspected snapshot and may differ if another
program edited the original. A `rollback-output-*` file can contain a concurrent
edit that could not be returned to its destination. Preserve those edits.

Compare the retained files with their mapped destination paths and restore only
the version you intend to keep. Do not blindly overwrite a current destination or
replay the whole manifest. RAW files marked `isReplaced: false` were held only to
validate the image while replacing its XMP companion. They still need restoration
if absent from their original path.

Once the affected files are reconciled and your backup is safe, remove the resolved
transaction directory and retry the job or Reset Job. Older retained directories
may have no manifest; retain their contents and determine their original paths
from the failed operation before restoring anything. No automatic recovery or
power-loss durability guarantee is implied by this manifest.

Cleanup errors distinguish a published replacement from an operation whose originals
were preserved or restored. A published replacement is not rolled back merely because
removing its recovery folder failed. Original backups may already have been deleted;
inspect the current destination and remaining files rather than assuming every manifest
entry still exists. Both outcomes report the recovery path and require reconciliation
before another reprocessing run.

The directory is private to the destination user, but its manifest contains photo
filenames. Keep recovery files out of shared diagnostics and source control.

## Repeatable process-interruption check

`Scripts/test-metadata-process-interruption.py` exercises the actual local publication
implementation with disposable nested RAW/XMP byte fixtures. Build the unit tests with
`xcodebuild build-for-testing`, then pass its generated unit-test `.xctestrun` file to
`python3 Scripts/test-metadata-process-interruption.py`. The script preserves Xcode's
`__TESTROOT__` paths and stores logs, result bundles and fixtures under `build/`.

The worker deliberately terminates itself with SIGKILL after preparation, after moving
originals into recovery, after publishing the XMP, and immediately before commit.
Each case requires Xcode's signal-9 failure plus an exact phase marker. A fresh test
host checks the manifest, original bytes, partial output and admission block, follows
the documented reconciliation choice, and completes a new publication. Both tests
skip unless the harness supplies its disposable fixture configuration. A skipped
verification cannot pass the harness.

This checks abrupt process termination at controlled transaction boundaries. It does
not prove power-loss durability, native recovery UI behavior, or camera RAW decoding.
