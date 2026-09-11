# M1/M3 guarded template persistence — 2026-09-11

Implementation commit: `fd17202`, following clean baseline `263562e`.

This checkpoint accepts explicit template records only behind compatible persistence
and interchange boundaries. Production preview, transfer and reprocessing deliberately
reject activated assignments until their frozen per-image context is integrated.
It does not enable variable editing or claim the complete sharing feature.

## Implemented behavior

Scheduled fields persist `templateVersions` for Headline, Description and the entire
ordered Keywords list; Copyright persists `copyrightTemplateVersion`. Language version
1 is supported, independently of local store schema 3, package version 3 and calendar
protocol 2. Missing markers keep legacy strings literal, including braces. Unknown,
null, Boolean, future and malformed markers fail; marked malformed source bodies fail
without falling back to older literal backups. Strict encoding also rejects invalid
active drafts created through existing raw property assignments. New validated mutators
replace source and activation together; existing editor bindings still need integration.

Copies, preset application and shared-document conversion preserve source/version pairs.
Active keyword sources keep their exact order, whitespace and duplicate entries until
resolution. Literal processing retains prior normalization. Calendar merge conflicts
compare each source/version pair atomically, including the entire keyword list.

Configuration export selects package 3 only for actually selected active content.
Literal and jobs-only selections retain package 2. Both plain and authenticated-decrypted
imports inspect the inner header and reject recognized markers mislabeled as package
1/2 before domain decoding. Header and nested marker preflight use Foundation Codable's
key semantics, avoiding JSONSerialization disagreement about duplicate keys. Encryption
envelope version stays 1. The old-version regression uses a frozen historical decoder
header gate; it is not execution of the installed 2.9.2 binary.

Legacy local stores reject recognized activation markers on read, encode and overwrite.
Versioned stores preserve unsupported or malformed active records, including malformed
siblings that could otherwise hide a marker during decoding. Save-time validation stops
stale cached state overwriting such records. This scan is confined to the four store
kinds containing templates, avoiding extra parsing on transfer manifest/signature paths.
Original legacy migration rejects markers, while current v3 validation accepts strict
valid active records. Startup provides a safe recovery category without payload text.

Calendar protocol 2 rejects active content before credentials/network, after suspended
requests, during receive/apply and in cached snapshots, conflicts and both receive-receipt
sides. Whole linked jobs are checked before date-range filtering. Save also checks an
existing valid-but-incompatible active calendar cache so stale literal state cannot
replace it. Detached local copies can preserve pairs; full server-enforced protocol 3
sharing and detached recovery UI remain open requirements.

The literal conversion boundary now throws for active assignments. Both production
transfer/reprocess calls and preview propagate rejection before the writer, and legacy
writer overloads use the same guard. In-memory typed requests retain persisted activation
and can resolve against explicitly supplied contexts; this is not yet production wiring.

## Review and validation

Independent reviews covered models, configuration, root processing/storage guards and
calendar copies/merges/transport/cache gates. Review fixes retained default literal
keyword normalization and prevented stale saves of incompatible cached state. Initial
builds exposed the new startup error switch case and a CommonCrypto fixture integer
mismatch; both were corrected. Logs are retained under `build/m3-guarded-activation/`.

Final suite: **794 discovered, 779 passed, 15 opt-in skips, zero failures**, exit 0
at 2026-09-11 09:36:06 Europe/Oslo, 37.670 seconds. The 31 new tests cover eight
model groups, eight package groups, seven calendar groups and eight boundary groups.
No source changes followed this successful run. A preceding test run found an
unsupported year-only date token in a fixture and changed migration encoding-error
precedence; the fixture now uses the supported date format, and encoding validation
again precedes marker parsing. The failed run is retained separately.

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

Environment: Xcode 26.6 (17F113), arm64 macOS 27.0 (26A428), development app 2.9.2 (37).
Installed stable copy unchanged. Tested dirty state was this reviewed source/project
slice and evidence/checklist documentation only.

- Log: `build/m3-guarded-activation/full-tests.log`
- SHA-256: `fec46069141095029672f84a01aa4553c1429a3d5ca14859e924adfac4758091`
- xcresult: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.11_09-35-24-+0200.xcresult`

The task inventory tool did not return this cycle and its pending read was stopped;
no shared desktop interaction was attempted. No native UI pass or manual checklist result is
claimed. The previous native accessibility timeout remains open; this cycle did not
repeat the same blind selection. Human result file remains absent.
