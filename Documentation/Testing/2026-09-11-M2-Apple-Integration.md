# Explicit Apple geocoding integration

Source: a9a5a14 on `codex/version-3-0-plan`, following `070e062`.
Status: reviewed implementation and integrated regression suite passed; no candidate readiness.

## Behavior

Geocoding has an explicit Location provider picker: Offline GeoNames or Apple online.
Choosing Apple opens a confirmation explaining that image GPS coordinates are sent to
Apple when needed, requiring network access, without requesting device location. The
choice becomes a draft only after affirmative confirmation. Cancel preserves the prior
settings, stale confirmations fail, and selecting a provider alone does not enable
variables or field writes. Saving persists the choice; switching offline clears consent.

Existing offline schema 1 remains byte-compatible and strict. Apple uses schema 2 with
an affirmative consent flag and fixed portable Apple policy identity; missing, false,
null, unknown or future semantics are rejected. Runtime adapter identity is recorded
separately: MapKit on macOS 26+, Core Location on earlier supported systems. Imports
remain stopped and the receiving user must explicitly approve Apple coordinate sharing
before importing jobs with Apple selected. Package content alone is not local consent.

Application-lifetime offline and Apple queues are constructed inertly. Production
transfer, reprocess and saved previews select the shared service from validated saved
settings only when a writable field/dependency needs a lookup and valid image coordinates
exist. No-result, provider failure, deadline/backoff or unavailable service never switches
to offline. Existing bounded queue/cache/coalescing/callback-lifetime behavior is retained.

Resolution evidence now records the attempted provider identity for failures as well
as successful results. Audit and preview distinguish provider outcomes from publication;
normal audit excludes image coordinates and place names. Existing audit data keeps its
optional shape. Missing GPS records that reason without constructing a request.

## Review and verification

Independent review covered schema compatibility, consent/stale drafts, routing, source
retention, privacy and no fallback. Review caught portable imported consent; the import
boundary and UI now require an explicit receiving-user decision before any mutation.

The first build failed before tests: Swift 6.3.3 crashed in IR generation for the
provider Binding method-reference actor thunk. Replacing the method reference with an
explicit closure preserves behavior and avoids that compiler path. The diagnostic is
retained in `build/m2-apple-integration/initial-compiler-failure.log`.

Full suite: **949 discovered, 934 passed, 15 opt-in skips, zero failures**, completed
2026-09-11 19:05:32 +0200 in 43.478 seconds, xcodebuild exit 0. Twenty-one tests added.
The application source was committed unchanged from the tested working tree; the
standalone probe was subsequently compiled and run separately. Environment: arm64
macOS 27.0 (26A428), Xcode 26.6 (17F113), Swift 6.3.3. App remains 2.9.2 (37), and the
installed stable app was not replaced.

```sh
xcodegen generate
xcodebuild test -project 'Aagedal FTP Sync.xcodeproj' -scheme AagedalFTPSync \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

- Passing log: `build/m2-apple-integration/full-tests.log`; SHA-256
  `de2480b5cd18b03f4d3801483ff2d15613d3b88ad69a30c7a98d4128bdc6b3bd`.
- Initial compiler failure SHA-256:
  `aba563093036afbbd165ba6540eb61b44b86afb91b8ac51f03b3acf92239fec7`.
- xcresult: `/Users/truls.aagedal/Library/Developer/Xcode/DerivedData/Aagedal_FTP_Sync-chqrijudhplttvgsyeeekhmacadi/Logs/Test/Test-AagedalFTPSync-2026.09.11_19-04-38-+0200.xcresult`.

## Native Apple probe

A separate explicitly opted-in executable linked the actual application queue and
Apple provider source. One fixed public Oslo city-centre pair (59.9139, 10.7522), locale
`nb_NO`, returned **Oslo / Norge** from `apple-online`, adapter `MapKit-26`, in 0.263
seconds; exit 0. This verifies one real request on this Mac, with correct Norwegian
country text. Network/service cache state is unknown; this is not a performance budget
or a supported-OS/general geography claim. No user photos, credentials or device location
were read. The desktop was untouched. The opt-in guard separately returned exit 2
without constructing a provider when the environment value was zero.

```sh
xcrun swiftc -swift-version 6 -parse-as-library \
  AagedalFTPSync/Metadata/MetadataGeocodingService.swift \
  AagedalFTPSync/Metadata/AppleMetadataGeocodingProvider.swift \
  Scripts/Probe-Apple-Geocoding.swift \
  -o build/m2-apple-integration/probe-apple-geocoding
FTP_SYNC_ALLOW_APPLE_PROBE=1 build/m2-apple-integration/probe-apple-geocoding
```

Compiler exit 0; Core Location deprecation warnings are expected for the deliberately
retained older-OS adapter. Native log `build/m2-apple-integration/native-probe.log`,
SHA-256 `d34e3e1282a461a288650e5f6a49bde478148486ce04b17434c1deb44064a9a9`.
Compile log `build/m2-apple-integration/native-probe-build.log`, SHA-256
`3878306b72433c58553e66060c38438cc2a3b5a3d53db1c3041a2598942e3f59`.
Independent review confirmed the probe's explicit opt-in and limited evidence claims.

The regression tests use injected Apple responses and disposable temporary files/stores, never the
user’s pictures or Apple networking. The routing matrix covers shared service reuse,
cache separation, absent consent, missing provider/no fallback, failure provenance,
preview, transfer, local reprocessing and processed-source retention. Schema tests cover
all required fields and malformed policies; consent tests cover affirmative/cancelled
and stale draft behavior. Import tests cover refusal before mutation and stopped imports.

## Open gates

- One live MapKit fixture passed on this Mac. Older-OS Core Location execution, live
  failure/recovery matrices and actual native UI remain unverified.
  The companion task remains active in native rotation/Metadata Review testing, so
  desktop use was deferred. Prior native XCTest authentication cancellation remains
  unresolved; it was not bypassed or retried unchanged.
- GeoNames rural/coastal/border evidence, real RAW interoperability, representative
  performance budgets and platform/runtime validation remain mandatory.
- M3 protocol3 sharing, M4 recognition/library/model lifecycle, M5 durable fingerprints
  and stale/incomplete filtering, and M6 candidate/release checks remain incomplete.
- Human checklist results remain absent and no manual gate is marked passed.
