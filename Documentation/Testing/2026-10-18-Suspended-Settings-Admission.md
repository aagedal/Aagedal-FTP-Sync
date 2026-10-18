# Settings admission after another copy is detected — 2026-10-18

## Reproduction

On base `2c2a831` plus pending setup changes, external-copy suspension cancelled
new sync/reset admission and disabled the main views, but did not reject all
settings writes at AppStore. A pending menu slider completion/disappearance
callback could still reach `updateInterval` and persist a changed jobs file.

A hosted regression saves a valid job, captures its bytes, suspends the store,
and invokes that callback path. Before the fix, all three unchanged-state
assertions failed: memory, decoded repository state and on-disk bytes changed.
Log: `build/suspended-settings-reproduction.log`, expected failure, exit 65.
Independent source review confirmed that disabled UI does not prevent already
queued or disappearance callbacks from reaching these store methods.

## Change

New configuration changes now require admission in AppStore's common jobs-write
helper and direct job/server credential, metadata programming, photographer,
preset, library/package import and calendar receiving-copy entry points. User
clearing of error history is blocked too. The check precedes credential staging
and import preparation. A rejected callback leaves saved state intact and repeats
the relaunch instructions rather than allowing another write through disabled UI.

Completion audit/failure recording and cleanup for already-admitted work remain
available while cooperative cancellation drains. Suspension remains latched;
observing that another copy disappeared does not resume the runtime or release
the storage lease. This is not a drain barrier or proof that all file I/O stopped.

## Verification

- Focused persistence, startup and audit selection: **88 tests, zero failures or
  skips**, exit 0, 1.468 seconds; `build/suspended-settings-focused.log`.
- A version-3 mutation matrix checks unchanged jobs/profiles/photographers/presets,
  JSON/backup bytes, Keychain values and write/removal counts after each rejected
  settings operation. It also covers the receiving-copy entry point.
- The actual startup-controller conflict test now invokes quick-control and Stop
  All callbacks after detecting a peer, retaining saved launch choices and lease.
- A completion-audit regression proves an already-completed operation can still
  append and publish its audit record after suspension.
- Full combined-worktree hosted target: **1,343 tests, 30 expected opt-in skips,
  zero failures**, exit 0, 42.195 seconds; `build/suspended-settings-hosted.log`.
- Signed native test compilation passes (`build/suspended-settings-ui-build.log`),
  as do the unsigned arm64 Release build (`build/suspended-settings-release.log`),
  bundled-model verification, security baseline, development identity 3.0.0 (44),
  and diff whitespace checks. Independent final review found no blockers.

All fixtures and credentials are disposable test data. No desktop interaction was
attempted, following the user's wait. The combined worktree includes pending
setup changes. Native conflict/queued-callback observation and broader 3.0 release
acceptance remain open.
