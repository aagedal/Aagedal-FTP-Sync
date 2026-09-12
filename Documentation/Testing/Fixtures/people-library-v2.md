# People-library schema-2 cross-app fixture

The sibling `people-library-v2.aagedalpeople` directory is an unpacked golden
package. Both Photo Agent
and FTP Sync must admit it without rewriting any declared file. A re-export must
preserve `people.json`, `editor/photo-agent.json`, and the FEM2 file byte-for-byte.

Pinned identities:

- library: `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa`
- person: `bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb`
- example: `cccccccc-cccc-cccc-cccc-cccccccccccc`
- core revision: `ba115ddf964e6e809ae82ac416347e12475d1b2df2a01940fabeff2a5392a281`
- overall revision: `87b48b311ab1056288116e2e90b57a585aca647e70d089f3636d6ae32cff3709`

The FEM2 vector has value `1.0` in dimension zero and zeros elsewhere. Its
little-endian header is the pinned integer magic `0x46454D32`, followed by the
dimension `512`. Valid FEM2 structure establishes vector validity only; the
manifest provides the required AuraFace model and preprocessing provenance.

Revision inputs are compact UTF-8 JSON encoded with sorted keys and unescaped
slashes. Core file declarations are sorted by ASCII path. `exportedAt` and
`exporter` are excluded from both revision inputs.

Core revision input:

```json
{"contract":{"componentID":"auraface-r100-coreml","dimension":512,"embeddingSpaceVersion":3,"l2Normalized":true,"modelID":"AuraFace-v1/glintr100","preprocessingRevision":"photo-agent-eyes112-rgb-v3","vectorEncoding":"fem2-float32-le"},"embeddingCount":1,"files":[{"byteCount":2056,"path":"embeddings/cccccccc-cccc-cccc-cccc-cccccccccccc.fem2","sha256":"c94edda6beea6aff7a41e7d6b6d6b9def72e024a8b10ccc78f7f900d0cd8c718"},{"byteCount":310,"path":"people.json","sha256":"defe59be76163a68585a9d56a54ab55ffd54385fb72167a400e634f9fd24a901"}],"format":"aagedal-known-people","libraryID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","peopleCount":1,"schemaVersion":2}
```

Overall revision input:

```json
{"coreRevision":"ba115ddf964e6e809ae82ac416347e12475d1b2df2a01940fabeff2a5392a281","editorPayload":{"byteCount":655,"mediaType":"application/vnd.aagedal.photo-agent-known-people+json;version=1","path":"editor/photo-agent.json","sha256":"97957271343108a13df0df5dfdd608ad0046b9e7ffaf73eef54b546f8af95d5a"},"format":"aagedal-known-people-snapshot","schemaVersion":2}
```

The editor JSON intentionally uses noncanonical whitespace and key order. Empty
strings, braces, Unicode, private source text, fractional dates, and the
`faceClothing` recognition mode must round-trip unchanged.

Editor payload keys are exact. The top-level object requires `format`,
`schemaVersion`, `libraryID`, `coreRevision`, `people`, and `examples`. Each
person value requires `createdAt` and `updatedAt`, with optional `role`, `notes`,
and `representativeThumbnailID`. Each example value requires `addedAt`, with
optional `sourceDescription` and `recognitionMode`; the only modes are `vision`
and `faceClothing`. Optional keys are omitted when absent and explicit null is
rejected. Dictionary keys and UUID values use lowercase canonical UUID strings.
The dictionaries cover exactly the core person/example IDs, and a representative
ID must belong to that person's examples. Dates are finite JSON numbers measuring
seconds since 2001-01-01.

When the editor payload exists, the manifest includes the exact descriptor keys
`path`, `mediaType`, `byteCount`, and `sha256`, and repeats the same file in
`files`. The path is `editor/photo-agent.json`; the media type is
`application/vnd.aagedal.photo-agent-known-people+json;version=1`. Unknown and
duplicate JSON keys are rejected throughout both payloads and the manifest.
