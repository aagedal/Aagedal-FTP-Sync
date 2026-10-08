# M5 linear collision validation — 2026-09-19

Source: clean `bcf354f368b39d72f38284f595b21d190faec7be` plus the changes
committed with this report on `codex/version-3-0-plan`.
Host: arm64 macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`). App: 2.9.2 (37).
No private results file was present. The tracked development candidate is unchanged.

## Change

Local destination collision validation previously byte-sorted every path,
allocating two UTF-8 arrays per sort comparison. It now visits paths once,
retaining the smallest spelling per comparison key and the collision pair with
the smallest second spelling (then first spelling to break ties). This preserves
the exact pair returned by the prior byte-sorted scan, independently of input
order. Comparison keys still use canonical Unicode normalization and POSIX
case folding; exact duplicate byte sequences remain allowed.

The new regression checks every permutation of five fixture groups (120 input
orders), including three competing spellings, exact duplicates, competing
collision groups, composed/decomposed accents, nested paths and non-collisions.
It compares the resulting bytes against the prior sorted algorithm, since Swift
String equality alone would hide differences in Unicode representation.
Existing generated-sidecar ownership and local publication integration tests
also pass. Recovery checks and file access validation are unchanged.

## Enriched benchmark

The existing opt-in integration benchmark exercises 50 images (25 generated
JPEGs and 25 opaque synthetic RAW files), real JPEG/XMP writes, deterministic
geocoding, read-only preflight, durable audit receipts and unchanged receipt
reuse. It checks metadata values and retained original/output bytes.

| Background files | Code | Preflight | Publication + audit | Current-receipt repeat |
| --- | --- | ---: | ---: | ---: |
| 0 | Before | 0.560 s | 1.466 s | 0.270 s |
| 0 | After | 0.666 s | 1.357 s | 0.204 s |
| 100,000 | Before | 6.670 s | 9.849 s | 6.255 s |
| 100,000 | After | 4.512 s | 8.350 s | 3.964 s |

The large-folder receipt repeat is 36.6% shorter in this comparison; preflight
is 32.3% shorter and publication plus audit 15.2% shorter. These are single
Debug samples on a shared host, not controlled release-budget evidence.
Both benchmark runs pass. Enumeration, signature lookup, production provider/
model workloads, cold/warm sampling, peak memory and native UI remain open.

## Verification

```sh
TEST_RUNNER_AAGEDAL_ENRICHED_REPROCESS_BENCHMARK=1 xcodebuild test \
  -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests/PathSafetyTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/LocalSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests CODE_SIGNING_ALLOWED=NO
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' -derivedDataPath build/v3-preview-consistency \
  -only-testing:AagedalFTPSyncTests CODE_SIGNING_ALLOWED=NO
Scripts/check-security-baseline.sh
Scripts/check-release-identity.sh
git diff --check
```

The before run selected only the enriched benchmark at the clean source revision.
Focused after selection: 120 executed, 116 passed, four opt-in skips, zero
failures, exit 0. Security/current-identity/diff checks pass.
Full non-UI suite: 1,223 executed, 1,198 passed, 25 opt-in skips, zero
failures, exit 0. Result bundles under `build/v3-preview-consistency/Logs/Test/`:

- Before: `Test-AagedalFTPSync-2026.09.19_23-13-06-+0200.xcresult`.
- Focused after: `Test-AagedalFTPSync-2026.09.19_23-14-30-+0200.xcresult`.
- Full: `Test-AagedalFTPSync-2026.09.19_23-16-10-+0200.xcresult`.

Test app: `build/v3-preview-consistency/Build/Products/Debug/Aagedal FTP Sync.app`
(unsigned). Executable SHA-256:
`b2fd270394fda3a66a18cce49ffac40e977db1d7c19ddd4fe18b6d3e282defab`.
Application-code `Contents/MacOS/Aagedal FTP Sync.debug.dylib` SHA-256:
`2abcbd450d66f6a037427cd4a441af7785dcf695cd77c9273bf93bfac72a1282`.

Logs: `build/v3-collision-before.log`, `build/v3-collision-after.log`,
`build/v3-collision-full.log`. Xcode required approved compiler/package cache
access after the sandboxed attempt could not load dependency manifests.
Other projects have active tasks on the shared desktop; no native UI acceptance
is claimed by this algorithm/performance slice. No milestone or agent checklist
case is marked passed.
