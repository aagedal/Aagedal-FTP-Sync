# Photo Agent People Library extension companion patch

Prepared on 2026-10-08 for the user-selected `.photoagentpeople` directory package
and `.photoagentpeople.zip` archive extensions. Legacy `.aagedalpeople` and
`.aagedalpeople.zip` inputs remain accepted. New exports require canonical names.

The patch is [photo-agent-people-extension.patch](../../Scripts/Patches/photo-agent-people-extension.patch),
against Photo Agent commit `2ea0ddf688e8148ffd1b857ea0a0ec0a14045e39`.
SHA-256: `04d873085897c19730159b38e03ec45f28a34605589bd8ff85b7db8cd1d0edc5`.
It was prepared in an ignored isolated source copy. The active Photo Agent checkout
was read-only and remained clean; the patch has not been integrated there.

The shared UTType identifier `no.aagedal.people-library`, manifest format, schema,
embedding contract and internal archive layout are unchanged. The plist lists the
canonical extension first and retains its legacy alias. Native picker defaults,
messages, export admission, directory writer and archive destination validation use
the canonical spelling. Import admission and the archive reader recognize both
extension families; unrelated ZIPs, mixed-case and malformed compound extensions
remain refused. Internal staging directory names are unchanged.

Tests in the patch parameterize real directory/archive admission with both extension
families and compare exact package bytes. Existing directory writer, archive round
trip and production export tests use canonical destinations. A new actual-writer
regression refuses both legacy export destinations without creating output. Naming
checks cover empty basename, mixed case and doubled/incorrect suffixes. Existing
legacy import, alias/link and security fixtures are retained.

Verification performed: `git apply --check` against the pinned, clean adjacent
checkout exited 0. Python plist decoding confirms both extensions and unchanged
UTType identity. Source inspection covered every production occurrence of the old
extension; no AGENTS.md was found in the checkout or checked parent locations.
The companion coordinator protocol and current readiness were inspected. No Xcode,
unit tests or native UI checks were run, and no commit or Git mutation was made in
the active companion checkout. These are prepared tests, not passing test evidence.

The Photo Agent coordinator must integrate/review the patch on an isolated branch,
run the affected suites and repository checks, then exercise native import/export
for both new and legacy inputs. Recheck the base revision before applying; a newer
companion branch may require rebasing. Confirm Finder package recognition and save
panel suffix behavior after Launch Services sees the new declaration. Finally prove
native Photo Agent export into FTP Sync and reverse import with the actual newly
built pair. This patch alone does not close native producer interchange or any
release-readiness gate.
