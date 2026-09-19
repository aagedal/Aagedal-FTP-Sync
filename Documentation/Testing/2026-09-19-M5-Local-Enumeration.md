# M5 local enumeration — 2026-09-19

Source: clean `bc652e4e8daf7fc779be08d8794876d791cdd83d` plus the changes
committed with this report on `codex/version-3-0-plan`.
Host: arm64 macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`). App: 2.9.2 (37).
No private results file was present. The tracked development candidate is unchanged.

## Change and safety evidence

The local enumerator previously standardized and resolved every file URL through
the filesystem. It now resolves the root's filesystem spelling once and derives
relative paths from the non-link-following directory enumerator. Full listings,
collision checks, metadata and hidden-file behavior are retained. Export and
publication still validate ancestors immediately before accessing a file; recovery
admission checks remain fresh at every existing boundary.

The root spelling must account for Foundation exposing `/var` while enumeration
returns `/private/var`. The first implementation missed this and failed integration
tests; the final implementation uses the root's canonical-path resource value and
verifies that it still resolves to the admitted root. A redirected root fails closed.
The final focused tests cover this actual temporary-directory alias.

Enumeration errors now propagate instead of returning a partial or empty listing.
Cancellation is checked before enumeration and at completion, including empty
folders. A pre-fix regression reproduces both a cancelled empty scan succeeding
and a removed root appearing empty (two failed assertions, exit 65).

Four new tests verify:

- Nested Unicode/space paths, hidden files, file sizes and dates remain intact.
- Package contents and internal staging files remain excluded; in-root, external
  and dangling symbolic links are not followed.
- Replacing an ancestor after listing is rejected by export.
- Empty cancellation, removed roots, root redirection and unreadable subtrees
  fail instead of returning misleading listing evidence.

## Enriched benchmark

The existing opt-in benchmark exercises 25 generated JPEGs and 25 opaque synthetic
RAW files with real JPEG/XMP metadata writes, deterministic geocoding, preflight,
durable audit receipts and an idle repeat. It verifies preserved source/RAW bytes,
resolved metadata and unchanged outputs during preflight and receipt reuse.
Fixture details and limits are in [the original benchmark report](2026-09-19-M5-Audit-Ordering-and-Enriched-Batch.md).

| Background files | Code | Preflight | Publication + audit | Current-receipt repeat |
| --- | --- | ---: | ---: | ---: |
| 0 | Before | 1.324 s | 3.256 s | 0.250 s |
| 0 | After | 0.918 s | 1.896 s | 0.208 s |
| 100,000 | Before | 8.770 s | 12.652 s | 8.306 s |
| 100,000 | After | 6.786 s | 11.747 s | 6.458 s |

One batch per folder size and code state, Debug build on a shared host. The
large-folder repeat is approximately 22% shorter in this comparison. Variance is
visible in the zero-background runs; these measurements are not controlled
cold/warm release budgets. Both benchmark runs pass. Remaining costs include
full listing, path collision reservation, signature queries and repeated recovery
checks. No production provider/model, camera RAW, peak-memory or native UI gate
is closed by these results.

## Commands and artifacts

```sh
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/LocalSyncIntegrationTests CODE_SIGNING_ALLOWED=NO
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_BENCHMARK=1 xcodebuild test \
  -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests/testLargeFolderEnrichedReprocessingBenchmark \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

Focused selection: 110 executed, 105 passed, five opt-in skips, zero failures,
exit 0. Benchmark: one test, no skips/failures, exit 0 for each code state.
Final complete non-UI suite: 1,222 executed, 1,197 passed, 25 opt-in skips,
zero failures, exit 0. Security/current-identity/diff checks pass.
Results in `build/v3-preview-consistency/Logs/Test/`:

- Full suite: `Test-AagedalFTPSync-2026.09.19_23-08-26-+0200.xcresult`.
- Final benchmark: `Test-AagedalFTPSync-2026.09.19_23-07-08-+0200.xcresult`.

Test app: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`
(unsigned). Executable SHA-256:
`b2fd270394fda3a66a18cce49ffac40e977db1d7c19ddd4fe18b6d3e282defab`.
Actual Debug application code, `Contents/MacOS/Aagedal FTP Sync.debug.dylib`,
SHA-256: `5e82eb2d1721d10736cc3ca616b8a9c68866c95e3d0ec501ca7f79b6d74b35f3`.

Xcode required approved compiler/package cache access after the sandboxed attempt
could not load dependency manifests.

Logs: `build/v3-listing-before.log` (expected pre-fix failure),
`build/v3-listing-full.log` (initial path-alias failure),
`build/v3-listing-focused.log`, `build/v3-listing-benchmark-before.log`,
`build/v3-listing-benchmark-after.log`, `build/v3-listing-full-final.log`.
Other projects had active tasks on the shared desktop; this slice uses disposable
non-UI fixtures. No milestone or agent checklist case is marked passed.
