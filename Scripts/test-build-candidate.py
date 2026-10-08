"""Reject mismatched or untraceable app identity before candidate registration."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("candidate", Path(__file__).with_name("build-3.0-candidate.py"))
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)


class CandidateTests(unittest.TestCase):
    def test_identity_rejects_each_mismatch_and_missing_revision(self):
        info = {"AFTSourceCommit": "a" * 40, "AFTSourceTree": "b" * 40,
                "CFBundleShortVersionString": "3.0.0", "CFBundleVersion": "43",
                "CFBundleIdentifier": "no.aagedal.AagedalFTPSync"}
        candidate.verify_identity(info, "a" * 40, "b" * 40, "3.0.0", "43")
        for key in info:
            with self.subTest(key=key):
                changed = dict(info)
                changed[key] = "wrong"
                with self.assertRaises(ValueError):
                    candidate.verify_identity(changed, "a" * 40, "b" * 40, "3.0.0", "43")
        del info["AFTSourceCommit"]
        with self.assertRaises(ValueError):
            candidate.verify_identity(info, "a" * 40, "b" * 40, "3.0.0", "43")

    def test_dirty_or_untracked_source_prevents_candidate(self):
        for status in [" M project.yml", "?? new-source.swift", "M  source.swift"]:
            with self.subTest(status=status), patch.object(candidate, "run", return_value=status):
                with self.assertRaises(ValueError):
                    candidate.source_identity()

    def test_used_build_is_rejected_across_commits_and_missing_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifacts = root / "candidates"
            registered = root / "registered.json"
            candidate.require_unused_build(artifacts, registered, "3.0.0", "43")
            previous = artifacts / "3.0.0-43-differentcommit"
            previous.mkdir(parents=True)
            with self.assertRaises(ValueError):
                candidate.require_unused_build(artifacts, registered, "3.0.0", "43")
            previous.rmdir()
            registered.write_text(json.dumps({"version": "3.0.0", "build": "43"}))
            with self.assertRaises(ValueError):
                candidate.require_unused_build(artifacts, registered, "3.0.0", "43")
            candidate.require_unused_build(artifacts, registered, "3.0.0", "44")
            candidate.require_unused_build(artifacts, registered, "3.0.1", "43")


if __name__ == "__main__":
    unittest.main()
