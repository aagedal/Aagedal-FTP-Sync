# Shared credential ownership — 2026-10-18

## Reproduction and fix

On base `b4706ad` plus pending setup changes, detaching a shared server into a
custom connection with the same password reused the shared profile's credential
ID. A later custom password change could remove that shared password during
jobs-only cleanup. Existing custom aliases were also vulnerable on job deletion.

The focused regression reproduced three failed assertions before the fix:
the shared ID was reused, its password disappeared after a later edit, and cleanup
included the shared ID. See `build/profile-credential-ownership-reproduction.log`
(expected failure, exit 65). Tests use temporary stores and an in-memory Keychain
substitute; they do not read or modify user credentials.

Custom connections now receive independent credential IDs when detached from a
profile. Saving an existing custom alias also separates its credential, including
when the supplied password is unchanged or empty. Job-save and deletion cleanup
retain all credentials referenced by current shared profiles as well as retained
custom jobs. The coordinator requires callers to provide current profiles, and
AppStore forwards them on both paths. Failed persistence rolls back newly staged
items while preserving the original profile and job.

Four new hosted regressions cover detachment followed by password rotation,
existing aliases with equal/changed/empty passwords, failed Keychain writes and
failed job commits, and actual AppStore save/delete paths. Independent source
and test review found no blockers.

## Verification

- Focused persistence/profile tests: **45 tests, zero failures or skips**;
  `build/profile-credential-ownership-focused.log`.
- Full combined-worktree hosted target: **1,336 tests, 30 expected opt-in skips,
  zero failures**, exit 0, 45.943 seconds;
  `build/profile-credential-ownership-full.log`.
- Signed native test compilation passes;
  `build/profile-credential-ownership-ui-build.log`.
- Unsigned arm64 Release build and bundled-model verification pass;
  `build/profile-credential-ownership-release.log`.
- Security baseline, development identity 3.0.0 (44), and diff whitespace checks pass.

The combined worktree includes pending setup/UI changes. Hosted tests and test
compilation do not establish native interaction acceptance. The user's desktop
wait remains in force; no native UI run was attempted. Native Jobs/setup/reset,
supported-OS, VoiceOver, remaining M5 and final candidate acceptance remain open.
