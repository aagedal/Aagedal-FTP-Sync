#!/usr/bin/env python3
"""Reassemble the pinned AuraFace weights before Xcode compiles the model."""

from __future__ import annotations

import hashlib
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PARTS = {
    "AuraFaceR100.weights.part-aa": "8c84c223e5c05ed4081b601c1efdf860e9ae46cc9aee306833fa41011f21b154",
    "AuraFaceR100.weights.part-ab": "0030dadb527f8f1b7d2fc8c76774e49b9493e1cec10c07e80e99af27f94bec91",
}
EXPECTED = "c189aaf7d6758dafb1603b4ea7f7c2161b69639434ddbce800e0cc632b26d7e0"


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def require_unlinked_directory(directory: Path, root: Path) -> None:
    """Keep model assembly inside the checkout even if a parent was replaced."""
    if not directory.is_relative_to(root):
        raise ValueError("AuraFace path is outside the checkout")
    if root.is_symlink() or not root.is_dir():
        raise ValueError("AuraFace checkout root is missing or linked")
    current = root
    for component in directory.relative_to(root).parts:
        current = current / component
        if current.is_symlink() or not current.is_dir():
            raise ValueError(f"AuraFace directory is missing or linked: {current}")


def prepare(*, root: Path = ROOT, part_hashes: dict[str, str] = PARTS,
            expected_weights_hash: str = EXPECTED) -> None:
    source_directory = root / "Tools/ModelSource"
    weights = root / "AagedalFTPSync/Resources/Models/AuraFaceR100.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
    require_unlinked_directory(source_directory, root)
    for name, expected in part_hashes.items():
        part = source_directory / name
        if part.is_symlink() or not part.is_file() or digest(part) != expected:
            raise ValueError(f"missing or changed AuraFace weights part: {name}")
    require_unlinked_directory(weights.parent.parent, root)
    weights.parent.mkdir(exist_ok=True)
    require_unlinked_directory(weights.parent, root)
    if weights.is_symlink():
        raise ValueError("AuraFace destination weights are linked")
    if weights.is_file() and digest(weights) == expected_weights_hash:
        return
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix=".weight.bin.", dir=weights.parent, delete=False
        ) as destination:
            temporary = Path(destination.name)
            for name in part_hashes:
                with (source_directory / name).open("rb") as source:
                    for chunk in iter(lambda: source.read(1024 * 1024), b""):
                        destination.write(chunk)
            destination.flush()
            os.fsync(destination.fileno())
        if digest(temporary) != expected_weights_hash:
            raise ValueError("reassembled AuraFace weights have the wrong hash")
        os.replace(temporary, weights)
        temporary = None
    except Exception:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    try:
        prepare()
    except (OSError, ValueError) as error:
        sys.exit(f"AuraFace preparation failed: {error}")
