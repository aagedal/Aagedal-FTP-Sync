# M5 processing fingerprint foundation

Date: 2026-09-12

Source revision: `1db573c707d4ef8ba77d2257927af0e443749a92`

Environment:

- macOS 27.0 (26A428), Apple silicon (`arm64`)
- Xcode 27.0 (27A266a)
- App version remains 2.9.2 (37); this is development evidence, not a release candidate

## Scope

This revision starts M5 processing provenance. It adds a strict schema-1
`MetadataProcessingFingerprint` to the optional portion of each metadata audit
entry and records it after a complete explicit local reprocess.

The receipt contains four lowercase SHA-256 revisions:

- source and RAW/XMP companion size/date evidence, with the same semantics as the
  source-signature store;
- the selected assignment, activated template revisions, field policies,
  geocoding/recognition choices, timestamp policy and persisted processing zone;
- immutable runtime dependency identities, currently the pinned metadata writer
  and the selected geocoder identity when geocoding ran;
- content hashes of the complete primary/sidecar output group.

Canonical payloads are domain-separated and length-delimited. Dictionary and
artifact ordering is normalized. The durable receipt contains no template source,
resolved metadata values, coordinates, local paths, face names, people-library
identifiers or provider error text. Unknown/missing receipt fields, future schema
versions and malformed digests fail decoding instead of being silently trusted.
Older audit entries remain compatible because the whole receipt is optional.

Reprocessing prefers current source listings, then the existing durable source
signature store, for source evidence. A legacy item with neither available uses
the destination listing as explicit bootstrap evidence. Output hashing checks
cancellation in bounded 1 MiB reads. It completes before publication, so a hash or
receipt-construction failure retains the original destination and creates a failed,
non-fingerprinted audit entry. Incomplete resolution likewise cannot receive a
complete fingerprint.

## Verification

The following selection passed with exit status 0. The seven selected classes
contain 75 declared test methods and cover canonicalization, independent source /
settings / dependency / output staleness, strict codec behavior, audit backup
compatibility, activated JPEG and RAW reprocessing, concurrent destination edits,
geocoding integration, and legacy/version-3 source-signature stores.

```sh
xcodebuild test -quiet \
  -project 'Aagedal FTP Sync.xcodeproj' \
  -scheme AagedalFTPSync \
  -destination 'platform=macOS' \
  -only-testing:AagedalFTPSyncTests/MetadataAuditTests \
  -only-testing:AagedalFTPSyncTests/MetadataProcessingAuditEvidenceTests \
  -only-testing:AagedalFTPSyncTests/ActivatedMetadataSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/MetadataGeocodingSyncIntegrationTests \
  -only-testing:AagedalFTPSyncTests/SourceSignatureRepositoryTests \
  -only-testing:AagedalFTPSyncTests/SourceSignatureSnapshotTests \
  -only-testing:AagedalFTPSyncTests/SourceSignatureVersion3Tests \
  CODE_SIGNING_ALLOWED=NO
```

The dependency guard also passed:

```sh
Scripts/check-security-baseline.sh
```

The worktree was clean at the tested source revision. No installed app, user data,
source photos, calendar server or companion checkout was changed.

## Open gates

This is a provenance foundation, not completion of M5. Regular/early transfer and
already-applied complete outcomes do not yet persist receipts. The audit repository
does not yet expose a newest-receipt index, and reprocessing has no stale/incomplete
filter UI. Face model/library dependency revisions await production runtime wiring.
Legacy destination bootstrap evidence must be replaced by a durable source receipt
before it can support strong source-staleness claims. The full validation matrix,
burst performance work, supported-OS checks and native UI verification remain open.
