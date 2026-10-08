#!/usr/bin/env python3
"""Contract checks for the opt-in external-reader verifier."""

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from verify_raw_xmp_integrity import VerificationError, compare_xmp, exiftool, verify


class RawXMPIntegrityVerifierTests(unittest.TestCase):
    def test_preserved_fields_and_expected_array_pass(self):
        before = {
            "XMP-dc:Subject": ["one, two", "Café"],
            "XMP-photoshop:Headline": "Keep me",
        }
        after = dict(before, **{"XMP-iptcExt:PersonInImage": ["Doe, Jane", "Åse"]})
        compare_xmp(before, after, {"XMP-iptcExt:PersonInImage": ["Doe, Jane", "Åse"]})

    def test_unapproved_field_change_fails(self):
        with self.assertRaisesRegex(VerificationError, "Unapproved XMP change"):
            compare_xmp(
                {"XMP-photoshop:Headline": "Before"},
                {"XMP-photoshop:Headline": "After", "XMP-photoshop:City": "Oslo"},
                {"XMP-photoshop:City": "Oslo"},
            )

    def test_missing_or_wrong_expected_field_fails(self):
        with self.assertRaisesRegex(VerificationError, "Expected XMP field missing"):
            compare_xmp({}, {}, {"XMP-photoshop:City": "Oslo"})
        with self.assertRaisesRegex(VerificationError, "expected 'Oslo'"):
            compare_xmp({}, {"XMP-photoshop:City": "Bergen"}, {"XMP-photoshop:City": "Oslo"})

    def test_unapproved_null_field_addition_or_removal_fails(self):
        for before, after in [({}, {"XMP-test:Null": None}), ({"XMP-test:Null": None}, {})]:
            with self.subTest(before=before):
                with self.assertRaisesRegex(VerificationError, "Unapproved XMP change"):
                    compare_xmp(before, dict(after, **{"XMP-photoshop:City": "Oslo"}),
                                {"XMP-photoshop:City": "Oslo"})

    def test_mismatched_sidecar_basename_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original = root / "source.CR3"
            output = root / "output.CR3"
            sidecar = root / "wrong.xmp"
            expected = root / "expected.json"
            for path in (original, output, sidecar):
                path.write_bytes(b"fixture")
            expected.write_text(json.dumps({"XMP-photoshop:City": "Oslo"}), encoding="utf-8")
            with self.assertRaisesRegex(VerificationError, "must match"):
                verify(original, output, None, sidecar, expected)

    def test_existing_source_sidecar_cannot_be_omitted(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original = root / "source.CR3"
            output = root / "output.CR3"
            source_xmp = root / "source.xmp"
            sidecar = root / "output.xmp"
            expected = root / "expected.json"
            for path in (original, output, source_xmp, sidecar):
                path.write_bytes(b"fixture")
            expected.write_text(json.dumps({"XMP-photoshop:City": "Oslo"}), encoding="utf-8")
            with self.assertRaisesRegex(VerificationError, "pass it with --before-xmp"):
                verify(original, output, None, sidecar, expected)

    def test_same_source_and_output_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            raw = root / "source.CR3"
            sidecar = root / "source.xmp"
            expected = root / "expected.json"
            raw.write_bytes(b"fixture")
            sidecar.write_bytes(b"fixture")
            expected.write_text(json.dumps({"XMP-photoshop:City": "Oslo"}), encoding="utf-8")
            with self.assertRaisesRegex(VerificationError, "RAW must be distinct"):
                verify(raw, raw, None, sidecar, expected)

    def test_matching_raw_and_external_xmp_fields_pass(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original = root / "source.CR3"
            output = root / "output.CR3"
            source_xmp = root / "source.xmp"
            sidecar = root / "output.xmp"
            expected = root / "expected.json"
            for path in (original, output, source_xmp, sidecar):
                path.write_bytes(b"fixture")
            expected.write_text(json.dumps({"XMP-photoshop:City": "Oslo"}), encoding="utf-8")
            camera = {"File:FileType": "CR3", "EXIF:Make": "Canon", "EXIF:Model": "R5",
                      "File:ImageWidth": 100, "File:ImageHeight": 100}
            source_fields = {"XMP-photoshop:Headline": "Keep me"}
            output_fields = dict(source_fields, **{"XMP-photoshop:City": "Oslo"})
            with patch("verify_raw_xmp_integrity.exiftool", side_effect=[camera, camera, source_fields, output_fields]):
                digest, raw_type, count = verify(original, output, source_xmp, sidecar, expected)
            self.assertEqual(raw_type, "CR3")
            self.assertEqual(count, 2)
            self.assertEqual(len(digest), 64)

    @unittest.skipUnless(shutil.which("exiftool"), "ExifTool is not installed")
    def test_real_external_reader_reports_unicode_xmp_fields(self):
        with tempfile.TemporaryDirectory() as folder:
            sidecar = Path(folder) / "probe.xmp"
            sidecar.write_text(
                '<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
                '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
                '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
                '<rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" '
                'photoshop:City="Oslo" photoshop:Headline="Café"/>'
                '</rdf:RDF></x:xmpmeta>\n<?xpacket end="w"?>',
                encoding="utf-8",
            )
            self.assertEqual(
                exiftool(sidecar, "-XMP:all"),
                {"XMP-photoshop:City": "Oslo", "XMP-photoshop:Headline": "Café"},
            )

    def test_opaque_bytes_with_raw_extension_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original = root / "source.CR3"
            output = root / "output.CR3"
            sidecar = root / "output.xmp"
            expected = root / "expected.json"
            original.write_bytes(b"synthetic RAW")
            output.write_bytes(original.read_bytes())
            sidecar.write_text("<x:xmpmeta xmlns:x='adobe:ns:meta/'/>", encoding="utf-8")
            expected.write_text(json.dumps({"XMP-photoshop:City": "Oslo"}), encoding="utf-8")
            with self.assertRaisesRegex(VerificationError, "ExifTool identifies"):
                verify(original, output, None, sidecar, expected)


if __name__ == "__main__":
    unittest.main()
