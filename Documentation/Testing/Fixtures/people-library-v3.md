# People Library schema 3 cross-app fixture

The sibling `people-library-v3.aagedalpeople` directory extends the pinned
schema 2 package with one upgrade-source JPEG. It keeps the same FEM2 vector,
library, person, and example IDs. The 320×320 JPEG is a synthetic color gradient,
not a photograph of a person. Both FTP Sync and Photo Agent should admit this
package from a directory and from a stored ZIP32 archive, then preserve the crop
bytes and example association on re-export.

- Library: `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa`
- Person: `bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb`
- Example and crop: `cccccccc-cccc-cccc-cccc-cccccccccccc`
- Core revision: `3747303528858361c874f656461ec6dfbcb005851e43b468baecec213294565f`
- Overall revision: `5e409e1e8d083d51b446eda5ba53c0e21104a157bbbec345f2851631007c1300`

`people.json` declares `upgrade_sources/cccccccc-cccc-cccc-cccc-cccccccccccc.jpg`
on that example. The manifest declares its exact byte count and SHA-256. The
editor payload is rebound to the schema 3 core revision, and its descriptor and
overall revision are recomputed. The FEM2 bytes are identical to the schema 2
fixture; the changed revisions come from the crop and actual schema version.

The crop was produced by resizing and JPEG-encoding the synthetic gradient test
image in Photo Agent's `AnalysisCorpus` with macOS `sips`. It is intentionally
small and has a complete JPEG stream ending in the EOI marker. The FTP Sync test
also builds a stored ZIP32 archive from these exact declared bytes to exercise
both transports.
