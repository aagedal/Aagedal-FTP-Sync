#!/usr/bin/env python3
"""Read-only, independent integrity check for a processed camera RAW/XMP pair.

The expectations file is an ExifTool JSON object, for example:
{"XMP-photoshop:City": "Oslo", "XMP-photoshop:Country": "Norway"}
Keys listed there are the only XMP fields allowed to change. An existing source
sidecar's other fields must remain identical when read by ExifTool.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path


RAW_TYPES = {"ARW", "CR2", "CR3", "DNG", "NEF", "ORF", "RAF", "RW2"}


class VerificationError(Exception):
    pass


def exiftool(path: Path, *tags: str) -> dict:
    result = subprocess.run(
        ["exiftool", "-j", "-a", "-G1", "-s", *tags, "--", str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise VerificationError(f"ExifTool could not read {path}: {result.stderr.strip()}")
    try:
        rows = json.loads(result.stdout)
        if len(rows) != 1 or not isinstance(rows[0], dict):
            raise ValueError("expected one metadata object")
        return {key: value for key, value in rows[0].items() if key != "SourceFile"}
    except (ValueError, TypeError) as error:
        raise VerificationError(f"Invalid ExifTool JSON for {path}: {error}") from error


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def compare_xmp(before: dict, after: dict, expected: dict) -> None:
    for key, value in expected.items():
        if key not in after:
            raise VerificationError(f"Expected XMP field missing: {key}")
        if after[key] != value:
            raise VerificationError(f"{key}: expected {value!r}, found {after[key]!r}")
    missing = object()
    for key in sorted((before.keys() | after.keys()) - expected.keys()):
        if before.get(key, missing) != after.get(key, missing):
            raise VerificationError(
                f"Unapproved XMP change in {key}: {before.get(key)!r} -> {after.get(key)!r}"
            )


def verify(before_raw: Path, after_raw: Path, before_xmp: Path | None,
           after_xmp: Path, expected_path: Path) -> tuple[str, str, int]:
    if shutil.which("exiftool") is None:
        raise VerificationError("ExifTool is required on PATH")
    for path in [before_raw, after_raw, after_xmp, expected_path, before_xmp]:
        if path is not None and not path.is_file():
            raise VerificationError(f"Missing regular file: {path}")
    if before_raw.samefile(after_raw):
        raise VerificationError("Source and output RAW must be distinct files")
    if before_xmp and before_xmp.samefile(after_xmp):
        raise VerificationError("Source and output XMP must be distinct files")
    if before_raw.suffix.lower() != after_raw.suffix.lower():
        raise VerificationError("RAW extensions differ")
    raw_type = before_raw.suffix[1:].upper()
    if raw_type not in RAW_TYPES:
        raise VerificationError(f"Unsupported camera RAW extension: {before_raw.suffix}")
    if after_xmp.suffix.lower() != ".xmp" or (before_xmp and before_xmp.suffix.lower() != ".xmp"):
        raise VerificationError("Sidecars must use .xmp")
    if after_xmp.stem != after_raw.stem or (before_xmp and before_xmp.stem != before_raw.stem):
        raise VerificationError("Each XMP sidecar must match its camera RAW basename")
    if before_xmp is None and any(before_raw.with_suffix(suffix).exists() for suffix in (".xmp", ".XMP")):
        raise VerificationError("Source XMP sidecar exists; pass it with --before-xmp")
    try:
        expected = json.loads(expected_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise VerificationError(f"Cannot parse expectations JSON: {error}") from error
    if not isinstance(expected, dict) or not expected or any(
        not isinstance(key, str) or not key.startswith("XMP-") for key in expected
    ):
        raise VerificationError("Expectations must be a nonempty object of ExifTool XMP group keys")

    original_hash = sha256(before_raw)
    if sha256(after_raw) != original_hash:
        raise VerificationError("Camera RAW bytes differ between source and output")
    for raw in [before_raw, after_raw]:
        tags = exiftool(raw, "-FileType", "-Make", "-Model", "-ImageWidth", "-ImageHeight")
        # FileType plus camera tags rejects arbitrary bytes with a RAW suffix.
        # It does not authenticate the file's camera provenance.
        if tags.get("File:FileType") != raw_type:
            raise VerificationError(f"{raw}: ExifTool identifies {tags.get('File:FileType')!r}, expected {raw_type}")
        if not any(key.endswith(":Make") and value for key, value in tags.items()) or not any(
            key.endswith(":Model") and value for key, value in tags.items()
        ):
            raise VerificationError(f"{raw}: missing camera Make/Model in external reader")
        if not any(key.endswith(":ImageWidth") for key in tags) or not any(
            key.endswith(":ImageHeight") for key in tags
        ):
            raise VerificationError(f"{raw}: missing image dimensions in external reader")

    before = exiftool(before_xmp, "-XMP:all") if before_xmp else {}
    after = exiftool(after_xmp, "-XMP:all")
    if not after:
        raise VerificationError("Output sidecar contains no externally readable XMP")
    compare_xmp(before, after, expected)
    return original_hash, raw_type, len(after)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before-raw", type=Path, required=True)
    parser.add_argument("--after-raw", type=Path, required=True)
    parser.add_argument("--before-xmp", type=Path, help="omit only when the source had no sidecar")
    parser.add_argument("--after-xmp", type=Path, required=True)
    parser.add_argument("--expect-json", type=Path, required=True)
    args = parser.parse_args()
    try:
        digest, raw_type, field_count = verify(
            args.before_raw, args.after_raw, args.before_xmp, args.after_xmp, args.expect_json
        )
    except VerificationError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PASS: {raw_type} RAW SHA-256 {digest}; {field_count} external XMP fields checked")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
