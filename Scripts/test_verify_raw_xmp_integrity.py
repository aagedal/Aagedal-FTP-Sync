#!/usr/bin/env python3
"""Contract checks for the opt-in external-reader verifier."""

import json
import tempfile
import unittest
from pathlib import Path

from verify_raw_xmp_integrity import VerificationError, compare_xmp, verify


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
