# M4 people-library admission and snapshot foundation

Implemented at `0beef3c0edae7f89d5f1c7b178f46464cf8cd1b3`, with the
matching foundation at parent source `e5ae9a7`. This is a strict local foundation;
ZIP extraction, user-facing import, model installation and recognition are not enabled.

## Contract and admission

- The proposed `aagedal-known-people` schema 2 manifest binds a persistent library
  UUID, stable revision, exact people/embedding counts, fixed AuraFace embedding
  space/model/preprocessing/vector contract and every payload file's length/SHA-256.
  Export time and exporter identity remain provenance but are excluded from revision,
  allowing an otherwise identical later re-export.
- Manifest and people payload admission is bounded before Codable allocation and
  rejects duplicate or escaped-equivalent JSON keys, unknown/missing keys, malformed
  nesting/trailing content, noncanonical UUIDs, unsafe paths, duplicate identities,
  mismatched references, count/byte overflows and unsupported contract values.
- People and example UUIDs bind exact lowercase paths. Names remain literal data.
  Every FEM2 vector is checked by the previously committed strict codec. Optional
  JPEGs require a complete single-image JPEG, bounded dimensions/pixels and a
  successful bounded pixel decode.

## Atomic local snapshots

- An injected app-owned repository copies from an unpacked source using no-follow
  descriptors, rejects non-regular/symlink/hardlinked entries and an unsafe writable
  repository root, verifies exact declared content, then seals an immutable revision
  directory before atomically changing a strict current pointer.
- Selection uses a cooperative lock, compare-and-swap generation and a persistent
  deselection record. This prevents an older staged import from activating across a
  selected-to-removed ABA transition. Failed validation or pre-activation faults keep
  the prior selection. Existing immutable snapshot handles remain usable after a
  replacement or removal.
- Loading re-verifies the exact bytes used for payload/vector decoding. A same-library,
  same-revision re-export can reorder declarations or change its export timestamp only
  when its contract and payload files remain identical. Snapshot cleanup is deliberately
  absent; no unknown directory is deleted.

## Review and verification

Independent security review found and the coordinator fixed: duplicate pointer keys,
selection ABA after removal, decoding separately from verified bytes, order-sensitive
revision reuse, metadata-only JPEG checks, partial/null pointer admission and a
group/world-writable root. The reviewer found no blocking issue after the fixes.

Focused tests: **7 passed, zero failures**, 3.271 seconds. They cover strict/canonical
manifest and payload admission, revision/reference/path binding, import/replacement/
removal, retained handles, invalid hashes, pre-activation failure, equivalent re-export,
installed-byte tampering, duplicate/null pointers and unsafe root permissions.
Log `build/m4-library/focused-tests-4.log`, SHA-256
`e1da1e36809aeac899b357b318e3ea525e070ab86608fbfd143092ea47de0afa`.

The first focused run failed two assertions because its all-numeric UUID fixture had no
case distinction; production behavior was not implicated. The fixture now contains hex
letters and proves lowercase wire enforcement. Initial log SHA-256
`550bad1994938e5df43991de8da3f04f293523393333f3e1e7d8c280f955739a`.

Full suite: **1,035 discovered, 1,020 passed, 15 opt-in skips, zero failures**,
78.930 seconds, completed 2026-09-12 12:41:36 +0200 on macOS 27.0 (26A428),
arm64, Xcode 26.6 (17F113). Log `build/m4-library/full-tests.log`, SHA-256
`6d67c7d4c3c38672a536f8cae774b20cfd5a91193906249534d9c2889d865ae6`.
Result bundle:
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.12_12-40-13-+0200.xcresult`.

No native/manual, actual archive extraction, real model, real face, companion export,
macOS 14 runtime or performance pass is claimed. The six M4 checklist cases and all 42
stable IDs are unchanged; the human results file remains absent.

## Next work

Implement a bounded archive extractor and settings/import UI, then integrate the
verified model installer, detector/alignment/embedder and bounded inference coordinator.
Add cancellation/CAS/link/corrupt-thumbnail adversarial coverage. The companion Photo
Agent exporter must implement and prove this hash-bound v2 contract, including rename
and removal replacement. Calibrated policy still requires authorized held-out real-face
fixtures and remains a separate release gate.
