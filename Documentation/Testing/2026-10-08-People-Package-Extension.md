# People package extension — 2026-10-08

The user selected `.photoagentpeople`, reserving the broader library name for
future use. FTP Sync now defaults to `People Library.photoagentpeople` and
requires that extension for new directory exports. Import accepts both the new
directory/archive names and legacy `.aagedalpeople`/`.aagedalpeople.zip` names.
Schema-2 wrapped ZIP roots may use either spelling. Schema-3 ZIPs retain the
existing flat, stored profile; no archive validation limits were relaxed.

The shared UTType identifier remains `no.aagedal.people-library`; its filename
aliases list the canonical name first. UI guidance, export helper, localization
catalog and current README are updated. Historical artifacts and golden fixtures
retain their original names to prove backwards-compatible import. Content,
manifest schema, embedding identity and revision hashes are unchanged.

Focused package/controller/cross-app/helper tests: 34 executed, two opt-in skips,
zero failures. Full non-UI regression: 1,284 executed, 30 opt-in skips, zero
failures. The skips remain unconfigured operator/integration tests, not passes.
Logs: `/private/tmp/aftpsync-v3-oct08-people-extension.log` and
`/private/tmp/aftpsync-v3-oct08-people-extension-integrated.log`.
Independent read-only FTP review found no blocking issue. Obsolete untranslated
localization keys noted in review were updated; JSON decoding and plist lint pass.

The [Photo Agent patch](Photo-Agent-People-Extension-Patch.md) is prepared against
its clean, pinned adjacent source. It has not been applied to that active checkout
or tested in native Photo Agent. This filename change does not close the decoder,
native exchange, macOS 14 or other open 3.0 release gates. Build 43 is the earlier
archive; the next changed-source archive needs a new build/candidate identity.

Clean source `50adea87b75076920dd15fb4aa28187dac966d08` generated the private
20-person package at
`build/face-evaluation/reference-library-02/Pseudonym Reference Library.photoagentpeople`.
The opt-in export/reimport test passes without skips, preserving all 178 query
outcomes. Log: `/private/tmp/aftpsync-v3-oct08-reference-export-new-extension.log`.
The earlier legacy-named package is retained as historical private evidence.
Independent review of the companion patch found no blocking issue; application
and native companion verification remain pending.
