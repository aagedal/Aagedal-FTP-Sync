# M4 lossless people-library packages

Implemented at `2dc18e9c4df7328eb59cb0503d7febcbad4acd56`. This is
the FTP Sync side of the proposed Photo Agent interchange contract. It is not yet
enabled in settings and does not claim companion-app compatibility until Photo Agent
ships and verifies the matching exporter/importer.

## Portable contract

- A `.aagedalpeople` directory package contains the strict schema-2 recognition
  snapshot. Import and export preserve every declared file exactly.
- The manifest now separates `coreRevision`, which binds the recognition payload,
  embedding contract and core file declarations, from the overall `revision`, which
  also binds an optional editor payload descriptor. Editor-only changes therefore do
  not alter recognition identity, but do create a distinct immutable snapshot.
- `editor/photo-agent.json` uses media type
  `application/vnd.aagedal.photo-agent-known-people+json;version=1`. It binds the same
  library UUID and core revision and preserves Photo Agent role, notes,
  representative-example selection, creation/update dates, source description,
  example date and `vision`/`faceClothing` mode. Optional values must be absent rather
  than null. Dates are finite seconds since 2001-01-01.
- Person and example metadata dictionaries must cover exactly the IDs in the core
  payload. A representative example must belong to that person. Unknown/duplicate
  keys, unknown modes, malformed identifiers, mismatched hashes and stale bindings
  fail admission.
- FTP Sync validates the editor JSON but treats its private source descriptions as
  opaque. It neither interprets nor displays them, and re-export preserves their exact
  bytes, including whitespace and key order.

The contract accepts only the pinned AuraFace v3 model/preprocessing/vector space.
Photo Agent's legacy Known People archives do not prove this provenance and must not
be relabeled as compatible. The companion flow needs durable compatible provenance or
explicit re-enrollment before it can produce a schema-2 package.

## Atomic import and export

- Export revalidates the immutable source, copies through no-follow descriptors into
  a private sibling stage, checks declared byte counts and SHA-256 values, revalidates
  source and stage, then publishes with an exclusive rename. Existing destinations are
  never replaced.
- Import applies the package service's conservative limits before creating or changing
  the receiving repository, then uses the repository's existing immutable snapshot and
  compare-and-swap selection path.
- Symlinked packages, hardlinked files, undeclared files, invalid extensions and source
  changes are rejected. Internal failures clean only the owned stage. Once an external
  publication hook can observe a stage, later failures preserve it instead of risking
  deletion of a substituted child.

This slice intentionally handles directory packages only. Bounded ZIP extraction,
settings panels, App Group entitlements and automatic synchronization remain open.
The automatic design is opt-in: Photo Agent is the sole editor/publisher, both apps
read one immutable current pointer in a shared App Group container, and neither app
reads the other's private Application Support directory.

## Review and verification

Independent review found two publication gaps: service-specific limits were not
applied before repository mutation, and post-hook cleanup could remove a substituted
child. Both were fixed. A later review requested an editor-bearing opaque round trip;
the added integration test imports, exports, reimports and re-exports deliberately
noncanonical JSON while preserving exact bytes. No source blocker remained.

Focused package suite: **7 passed, zero failures**, 0.587 seconds. Log
`/tmp/ftp-m4-package-focused-2.log`, SHA-256
`9e2ed510cc27d5f31e04298ac9ea46566c1ec02dfb967a4e263e5f47f2893347`.

Full suite: **1,045 discovered, 1,030 passed, 15 opt-in skips, zero failures**,
50.738 seconds (51.180 wall), completed 2026-09-12 13:22:32 +0200 on macOS
27.0 (26A428), arm64, Xcode 26.6 (17F113). The standard repository command used
`CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO`. Log
`build/m4-library-package/full-tests.log`, SHA-256
`201cb05e37ba0125a917c4f3ebe5e9e47127e7ba2656a8bc986d181ae3c86fc0`.
Result bundle:
`/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.12_13-21-38-+0200.xcresult`.

An earlier signed/default full-suite invocation ran the sandboxed host and produced
157 unrelated permission/loopback failures against `/private/tmp`; the focused people
library suites passed in that run. Re-running the documented unsigned, serial command
passed all non-opt-in tests.

No native/manual UI, ZIP extraction, shared-container synchronization, companion
round trip, real model, real face, supported-macOS matrix or release acceptance is
claimed. The human result file remains absent.
