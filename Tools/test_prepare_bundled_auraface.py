#!/usr/bin/env python3
"""Failure and path-safety checks for the bundled-model assembly step."""

from __future__ import annotations

import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("prepare_bundled_auraface.py")
spec = importlib.util.spec_from_file_location("prepare_bundled_auraface", SCRIPT)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PrepareBundledAuraFaceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "checkout"
        self.parts = self.root / "Tools/ModelSource"
        self.weights = self.root / (
            "AagedalFTPSync/Resources/Models/AuraFaceR100.mlpackage/"
            "Data/com.apple.CoreML/weights/weight.bin"
        )
        self.parts.mkdir(parents=True)
        self.weights.parent.mkdir(parents=True)
        self.first = b"first model part"
        self.second = b"second model part"
        (self.parts / "part-aa").write_bytes(self.first)
        (self.parts / "part-ab").write_bytes(self.second)
        self.hashes = {
            name: hashlib.sha256(data).hexdigest()
            for name, data in (("part-aa", self.first), ("part-ab", self.second))
        }
        self.expected = hashlib.sha256(self.first + self.second).hexdigest()

    def prepare(self) -> None:
        module.prepare(root=self.root, part_hashes=self.hashes,
                       expected_weights_hash=self.expected)

    def assert_no_temporary_weights(self) -> None:
        self.assertEqual(list(self.weights.parent.glob(".weight.bin.*")), [])

    def test_assembles_verified_parts_and_replaces_invalid_destination(self) -> None:
        self.weights.write_bytes(b"old invalid model")
        self.prepare()
        self.assertEqual(self.weights.read_bytes(), self.first + self.second)
        self.assert_no_temporary_weights()

    def test_failed_replace_preserves_destination_and_removes_temporary_file(self) -> None:
        self.weights.write_bytes(b"old invalid model")
        with patch.object(module.os, "replace", side_effect=OSError("interrupted")):
            with self.assertRaisesRegex(OSError, "interrupted"):
                self.prepare()
        self.assertEqual(self.weights.read_bytes(), b"old invalid model")
        self.assert_no_temporary_weights()

    def test_changed_part_preserves_destination(self) -> None:
        self.weights.write_bytes(b"old invalid model")
        (self.parts / "part-ab").write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "changed AuraFace weights part"):
            self.prepare()
        self.assertEqual(self.weights.read_bytes(), b"old invalid model")
        self.assert_no_temporary_weights()

    def test_missing_weights_directory_is_created_inside_checkout(self) -> None:
        self.weights.parent.rmdir()
        self.prepare()
        self.assertEqual(self.weights.read_bytes(), self.first + self.second)

    def test_linked_weights_directory_cannot_redirect_assembly(self) -> None:
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        self.weights.parent.rmdir()
        self.weights.parent.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "missing or linked"):
            self.prepare()
        self.assertEqual(list(outside.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
