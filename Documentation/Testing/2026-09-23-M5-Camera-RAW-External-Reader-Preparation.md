# M5 camera RAW / external-reader preparation — 2026-09-23

The repository currently tracks no camera RAW fixture (`.CR2`, `.CR3`, `.NEF`,
`.ARW`, `.DNG`, `.RAF`, `.ORF`, `.RW2`) or XMP sidecar. Existing RAW integration
tests deliberately use opaque byte strings or JPEG data routed through a RAW
extension. They establish transfer and sidecar policy, but cannot establish
camera-format decoding or interoperability. ExifTool 13.55 is available on
this macOS host. No private image library was inspected for fixtures.

`Scripts/verify_raw_xmp_integrity.py` is a read-only acceptance aid for a
user-supplied camera RAW source and a processed output. It requires ExifTool
to recognize both RAW files as the named format and to read their camera
Make/Model and dimensions. It streams SHA-256 over both RAW files, then uses
ExifTool to compare all externally readable XMP fields. Only keys explicitly
listed in an expectations JSON file may differ. The expected output values,
including ordered arrays and Unicode text, must match exactly. For a new
sidecar, omit `--before-xmp`; the output must still have readable XMP.

Example after processing a disposable `.CR3` pair:

```sh
cat > /tmp/raw-xmp-expected.json <<'JSON'
{
  "XMP-photoshop:City": "Oslo",
  "XMP-photoshop:Country": "Norway",
  "XMP-iptcExt:PersonInImage": ["Doe, Jane", "Åse"]
}
JSON
python3 Scripts/verify_raw_xmp_integrity.py \
  --before-raw /path/to/source/photo.CR3 \
  --before-xmp /path/to/source/photo.xmp \
  --after-raw /path/to/output/photo.CR3 \
  --after-xmp /path/to/output/photo.xmp \
  --expect-json /tmp/raw-xmp-expected.json
```

Run `exiftool -j -a -G1 -s -XMP:all /path/to/output/photo.xmp` first to
confirm the exact group keys and array representation for the expected tags.
Use different before/after directories for a processed source. Record the
fixture camera/model, licensing or authorization, ExifTool version, command,
hash and field comparison result when this matrix is run. Retain the original
and output only in an authorized fixture location; the verifier writes neither.

Verifier contract tests pass: `python3 Scripts/test_verify_raw_xmp_integrity.py`
ran 4 tests, zero failures. They check preserved unrelated XMP, exact Unicode
array comparison, missing/mismatched expected fields and rejection of opaque
bytes renamed `.CR3`. A disposable ExifTool-produced XMP probe confirmed the
actual `XMP-photoshop:City` and `XMP-photoshop:Country` group keys. No camera
RAW pair was available to execute the acceptance command, so camera RAW,
Photo Agent display and supported-macOS acceptance remain open.
