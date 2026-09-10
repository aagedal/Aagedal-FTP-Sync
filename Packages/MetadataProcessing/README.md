# MetadataProcessing

Local Swift 6 package; `MetadataTemplates` runs on macOS 14 or later and has no
external dependencies. The package does not read files, settings, metadata or the
clock, perform lookups, or write fields.

## Version 1 template contract

`MetadataTemplateText` and `MetadataTemplateKeywords` keep source and the optional
language-version marker as an immutable, equatable pair. Create `.literal(source)`
for legacy data or `try .activated(source)` after an explicit activation decision.
The throwing `init(source:templateVersion:)` accepts nil (literal) or integer 1
(active), rejecting other versions and validating active syntax before constructing
the replacement. An invalid replacement leaves the previously assigned value intact;
keep editor drafts separately. There are no independent source/marker setters.
Equality includes activation, so merge logic can compare the entire pair.

Literal values bypass parsing and resolve to the exact source, including braces,
escapes, and keyword blanks/duplicates/order. Active text delegates to the parser;
active keywords validate and resolve the complete array together. Both types expose
`requiredVariables`, empty for literals. Literal values bypass the template safety
bounds too; integration must retain its existing literal field validation and
normalization policies. `MetadataTemplate.parse` remains available for validating
editor drafts without committing activation.

The types' strict Codable **core envelope** is `{"source":"…","templateVersion":1}`
(Keywords uses an array for `source`). A missing marker means literal and encodes
without the marker. Explicit null, booleans, wrong source shapes, unsupported
versions and unknown envelope keys reject rather than falling back to literal.
Unknown-key rejection applies to this core envelope only. It is not the proposed
app/calendar wire format: adapters must map Headline/Description/Keywords markers
and Copyright's marker to complete values while enforcing their own schema gates.
Decoding and encoding never replace persisted source with a resolved sample.
App storage migration, per-field marker adapters, package/calendar compatibility
and UI activation remain unimplemented; using these value types alone does not
establish those compatibility guarantees.

Supported tokens are `{photographer}`, `{gps:city}`, `{gps:country}`, `{persons}`,
`{date:YYYY-MM-DD}`, and `{dateCaptured:YYYY-MM-DD}`. The only date-format alias is
`yyyy-MM-dd`; unformatted date tokens and every other format are invalid. `{{` and
`}}` each produce a literal brace. Unknown tokens, nested/unmatched braces and
unsupported formats throw `MetadataTemplateParseError` with a zero-based UTF-8
offset. Source is limited to 16 KiB of UTF-8 per field/keyword entry; resolved text
is limited to 64 KiB. These are processing safety limits, not metadata-format limits;
the metadata writer must still enforce its own field constraints.

Construct an immutable `MetadataTemplateContext` once per operation, supplying the
captured processing instant and persisted job time zone. Reuse that context across
fields and retries. A later explicit reprocess may create a new context. Supply the
matched profile's canonical photographer name, including its legacy-name fallback.
Missing, empty or whitespace-only text is unavailable; supplied nonempty text is
otherwise preserved literally. Location/person values should remain nil until the
corresponding services or existing metadata provide usable values. The context's
persons list must already merge existing and accepted names in stable order. Blank
names are skipped and `{persons}` joins usable names with `, `.

`MetadataCaptureDate` requires explicit zone provenance: the EXIF offset (whole
minutes within ±14 hours), or the identifier of the persisted job fallback zone.
Invalid zones fail construction. The caller must interpret offset-free EXIF wall
clock components in that selected fallback zone **before** passing the resulting
`Date`; this package does not parse EXIF. Preserve `zoneSource` for preview/audit so
the user sees assumptions. Dates use proleptic Gregorian civil-date arithmetic and numeric
year/month/day formatting independent of the machine's locale/calendar/time zone.
The calendar applies Gregorian leap-year rules before 1582 as well as after it;
there is no Julian cutover. Date fractions cannot round across a day boundary.
No capture date fallback to the processing date occurs. Unsupported years (outside
1–9999 CE) and nonfinite instants return a typed preservation outcome.

```swift
let template = try MetadataTemplateText.activated("Photo: {photographer}, {date:YYYY-MM-DD}")
switch template.resolve(using: frozenContext) {
case .resolved(let text):
    // Propose this entire field, subject to the existing metadata write policy.
    proposedDescription = text
case .preserveExisting(let reason):
    // Preserve the current field and report the missing values/limit/date error.
    previewOmissions.append(reason)
}
```

Expansion is a single pass over parsed segments. Braces in supplied values remain
literal, with no recursive expansion. A preservation outcome never exposes partial
text. `resolveKeywords` resolves the entire list atomically; if any entry cannot
resolve, preserve the existing keyword list. It trims entries, drops empty values,
and deduplicates case/diacritics using fixed `en_US_POSIX` folding while retaining
the first spelling/order. A comma inside an expanded value never creates entries.
The helper limits input to 1,024 entries and total unique resolved UTF-8 to 64 KiB.
Accepted face names may be appended separately by integration even when scheduled
keywords were preserved. Persistence, field-policy assessment, preview UI and
metadata writing are intentionally caller responsibilities.

## Provenance and verification

The supported spelling/date-alias behavior was compared with Photo Agent's
`Aagedal Photo Agent/Utilities/PresetVariableInterpolator.swift`, clean at revision
`a7392e393ba584d8cc613e11562f967c4539d2b3` on 2026-09-09. This is a purpose-built
implementation of FTP Sync's narrower contract; no Photo Agent source was copied.
It deliberately omits that interpolator's implicit current dates, arbitrary date
formats, recursive field references and missing-value removal.

Run `swift test --package-path Packages/MetadataProcessing` from the repository
root. Pure unit tests cover syntax, Unicode and byte bounds, escaping, dates and
zone provenance, missing values, single-pass substitution, keyword atomicity and
normalization, strict activation decoding, unchanged legacy literals, source/version
round trips and failed atomic replacements. App integration and real metadata/GUI behavior require separate
verification and are not established by these tests.

## App integration

The app now links this package through `MetadataProcessingCoordinator`. Existing
preview/transfer/reprocess paths use its literal snapshot entry point. Explicit
in-memory activation resolves against a supplied frozen context with per-field
outcomes and pinned writer limits; production UI/persistence does not yet activate
those requests. App-level literal keyword overrides use the existing normalization
policy; the package literal codec itself remains exact. See the
[processing/storage checkpoint](../../Documentation/Testing/2026-09-10-M1-Processing-Storage-Integration.md)
for verification and the remaining context, encoding and completion gates.
