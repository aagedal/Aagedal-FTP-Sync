# M4 lossless people-library packages

Package foundation implemented at `2dc18e9c4df7328eb59cb0503d7febcbad4acd56`;
settings and admitted-runtime lifecycle implemented at
`da3579e81320e7cb1ecac03d5d2faae93ddfed05`. This is the FTP Sync side of the
proposed Photo Agent interchange contract. It does not claim companion-app
compatibility until Photo Agent ships and verifies the matching exporter/importer.

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

This slice intentionally handles directory packages only. The v3 settings panel can
import a selected package, export the selected immutable snapshot under a new name,
show its non-private summary and clear the current selection. Operations run outside
the main actor, serialize, retain the prior selection on failure, suppress stale
completion after suspension and hold security-scoped access for the whole operation.
The repository is rooted only in admitted v3 storage and is suspended with the rest
of the app before an external writer can take over. Bounded ZIP extraction, App Group
entitlements and automatic synchronization remain open.
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

The committed cross-app golden package is
`Documentation/Testing/Fixtures/people-library-v2.aagedalpeople`, with its exact
revision inputs documented beside it. Its accepted vector has deliberate norm drift
within the contract tolerance, so normalization and re-encoding changes bytes. FTP
Sync admitted and re-exported all four declared files byte-for-byte in the integrated
focused run.

Integrated focused run: **25 passed, zero failures**, covering the controller,
package service, storage layout and v3 bootstrap. Full suite: **1,050 discovered,
1,035 passed, 15 opt-in skips, zero failures**, 58.156 seconds (58.435 wall),
completed 2026-09-12 14:06:47 +0200 on macOS 27.0 (26A428), arm64,
Xcode 27.0 (27A266a). Both runs used `CODE_SIGNING_ALLOWED=NO`, serial testing and
the isolated `build/DerivedData-people-settings` path. Full result bundle:
`build/DerivedData-people-settings/Logs/Test/Test-AagedalFTPSync-2026.09.12_14-05-45-+0200.xcresult`.

An earlier signed/default full-suite invocation ran the sandboxed host and produced
157 unrelated permission/loopback failures against `/private/tmp`; the focused people
library suites passed in that run. A later golden-only rerun encountered a stale
global SDK stat-cache path before tests started. Re-running the documented unsigned,
serial command with isolated DerivedData passed all non-opt-in tests.

No native/manual settings UI, ZIP extraction, shared-container synchronization, companion
round trip, real model, real face, supported-macOS matrix or release acceptance is
claimed. The human result file remains absent.
