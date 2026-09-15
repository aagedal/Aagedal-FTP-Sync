#!/usr/bin/env python3
"""Verify the reviewed AuraFace package and the compiled payload in an app."""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

PACKAGE_HASHES = {
    "Manifest.json": "d2d7d38c9b21464299e620f0b87bf8037fde9d776174b9fc871508c4eb92be0a",
    "Data/com.apple.CoreML/model.mlmodel": "b60588562fd76717d0d6ddcfcb8a4bf2d2bda3d61b356721b379318adf366f85",
    "Data/com.apple.CoreML/weights/weight.bin": "c189aaf7d6758dafb1603b4ea7f7c2161b69639434ddbce800e0cc632b26d7e0",
}
COMPILED_FILES = {
    "model.mil", "coremldata.bin", "weights/weight.bin"
}


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def checked_file(root: Path, relative: str) -> Path:
    path = root / relative
    if (path.is_symlink() or not path.is_file() or path.stat().st_size == 0
            or not path.resolve(strict=True).is_relative_to(root.resolve(strict=True))):
        raise ValueError(f"missing or linked file: {relative}")
    return path


def verify_source(package: Path) -> None:
    if package.is_symlink() or not package.is_dir():
        raise ValueError("AuraFace .mlpackage is missing or linked")
    if any(path.is_symlink() for path in package.rglob("*")):
        raise ValueError("AuraFace package contains a symbolic link")
    actual_files = {
        str(path.relative_to(package)) for path in package.rglob("*") if path.is_file()
    }
    if actual_files != set(PACKAGE_HASHES):
        raise ValueError("AuraFace package file inventory differs from the reviewed package")
    for relative, expected in PACKAGE_HASHES.items():
        if digest(checked_file(package, relative)) != expected:
            raise ValueError(f"AuraFace source hash differs: {relative}")
    if not (package.parent / "AuraFace-LICENSE.md").is_file():
        raise ValueError("AuraFace license notice is missing")


def verify_app(app: Path) -> None:
    if app.is_symlink() or not app.is_dir() or app.suffix != ".app":
        raise ValueError("expected an existing app bundle")
    resources = app / "Contents/Resources"
    model = resources / "AuraFaceR100.mlmodelc"
    if model.is_symlink() or not model.is_dir():
        raise ValueError("compiled AuraFace model is missing or linked")
    for relative in COMPILED_FILES:
        checked_file(model, relative)
    weights = checked_file(model, "weights/weight.bin")
    if digest(weights) != PACKAGE_HASHES["Data/com.apple.CoreML/weights/weight.bin"]:
        raise ValueError("compiled AuraFace weights differ from the reviewed package")
    if not (resources / "AuraFace-LICENSE.md").is_file():
        raise ValueError("AuraFace license notice is missing from the app")
    if (resources / "AuraFaceR100.mlpackage").exists():
        raise ValueError("uncompiled AuraFace package duplicated in the app")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("source", "app"))
    parser.add_argument("path", type=Path)
    args = parser.parse_args()
    try:
        (verify_source if args.kind == "source" else verify_app)(args.path)
    except (OSError, ValueError) as error:
        sys.exit(f"AuraFace verification failed: {error}")
    print(f"AuraFace {args.kind} verified: {args.path}")


if __name__ == "__main__":
    main()
