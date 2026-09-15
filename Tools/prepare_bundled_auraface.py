#!/usr/bin/env python3
"""Reassemble the pinned AuraFace weights before Xcode compiles the model."""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PARTS = {
    "AuraFaceR100.weights.part-aa": "8c84c223e5c05ed4081b601c1efdf860e9ae46cc9aee306833fa41011f21b154",
    "AuraFaceR100.weights.part-ab": "0030dadb527f8f1b7d2fc8c76774e49b9493e1cec10c07e80e99af27f94bec91",
}
WEIGHTS = ROOT / "AagedalFTPSync/Resources/Models/AuraFaceR100.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
EXPECTED = "c189aaf7d6758dafb1603b4ea7f7c2161b69639434ddbce800e0cc632b26d7e0"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def prepare() -> None:
    source_directory = ROOT / "Tools/ModelSource"
    for name, expected in PARTS.items():
        part = source_directory / name
        if part.is_symlink() or not part.is_file() or digest(part) != expected:
            raise ValueError(f"missing or changed AuraFace weights part: {name}")
    if WEIGHTS.is_file() and not WEIGHTS.is_symlink() and digest(WEIGHTS) == EXPECTED:
        return
    WEIGHTS.parent.mkdir(parents=True, exist_ok=True)
    if WEIGHTS.is_symlink():
        WEIGHTS.unlink()
    try:
        with WEIGHTS.open("wb") as destination:
            for name in PARTS:
                with (source_directory / name).open("rb") as source:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        destination.write(chunk)
            destination.flush()
            os.fsync(destination.fileno())
        if digest(WEIGHTS) != EXPECTED:
            raise ValueError("reassembled AuraFace weights have the wrong hash")
    except Exception:
        WEIGHTS.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    try:
        prepare()
    except (OSError, ValueError) as error:
        sys.exit(f"AuraFace preparation failed: {error}")
