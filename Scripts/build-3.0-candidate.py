#!/usr/bin/env python3
"""Archive a clean, traceable Developer ID build without installing or publishing it."""

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args, capture=False):
    result = subprocess.run(args, cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def verify_identity(info, commit, tree, version, build):
    expected = {"AFTSourceCommit": commit, "AFTSourceTree": tree,
                "CFBundleShortVersionString": version, "CFBundleVersion": build,
                "CFBundleIdentifier": "no.aagedal.AagedalFTPSync"}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Archived app {key} does not match the candidate source")


def source_identity():
    # Include untracked source, but ignore build outputs and machine-local signing.
    if run("git", "status", "--porcelain", "--untracked-files=normal", capture=True):
        raise ValueError("Commit source changes before building a candidate; the worktree must be clean")
    return (run("git", "rev-parse", "HEAD", capture=True),
            run("git", "rev-parse", "HEAD^{tree}", capture=True))


def write_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".candidate-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team-id", required=True, help="Developer ID team used for signing")
    parser.add_argument("--register", action="store_true", help="Point the manual checklist at this development candidate")
    args = parser.parse_args()
    commit, tree = source_identity()
    spec = (ROOT / "project.yml").read_text()
    version = re.search(r"^\s+MARKETING_VERSION: ([0-9.]+)$", spec, re.M).group(1)
    build = re.search(r"^\s+CURRENT_PROJECT_VERSION: ([0-9]+)$", spec, re.M).group(1)
    run("Scripts/check-release-identity.sh", version, build)
    run("Scripts/check-security-baseline.sh")
    artifact_root = ROOT / "build" / "candidates" / f"{version}-{build}-{commit[:12]}"
    if artifact_root.exists():
        raise ValueError(f"Candidate output already exists; preserve it and use a new build number: {artifact_root}")
    artifact_root.mkdir(parents=True)
    archive = artifact_root / "Aagedal FTP Sync.xcarchive"
    run("xcodebuild", "archive", "-project", "Aagedal FTP Sync.xcodeproj",
        "-scheme", "AagedalFTPSync", "-configuration", "Release",
        "-destination", "generic/platform=macOS", "-archivePath", str(archive),
        "-derivedDataPath", str(artifact_root / "DerivedData"),
        "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=Developer ID Application",
        f"DEVELOPMENT_TEAM={args.team_id}", f"AFT_SOURCE_COMMIT={commit}", f"AFT_SOURCE_TREE={tree}")
    if source_identity() != (commit, tree):
        raise ValueError("Source changed during the archive; candidate not registered")
    app = archive / "Products/Applications/Aagedal FTP Sync.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    verify_identity(info, commit, tree, version, build)
    run("codesign", "--verify", "--deep", "--strict", str(app))
    run("python3", "Tools/verify_bundled_auraface.py", "app", str(app))
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    hasher = hashlib.sha256()
    with executable.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    candidate = {
        "schemaVersion": 1, "id": f"development-{version}-{build}-{commit[:12]}-{digest[:12]}",
        "status": "IMPLEMENTING", "commit": commit, "sourceTree": tree,
        "version": version, "build": build, "appPath": str(app),
        "executableSHA256": digest, "archivePath": str(archive),
        "evidence": "Documentation/3.0-Readiness.md",
        "note": "Developer ID signed Release archive from clean source. Not notarized or published by this workflow. Required acceptance gates remain open; this is not READY_FOR_USER_TESTING."
    }
    write_json(artifact_root / "candidate.json", candidate)
    if args.register:
        # A new ID preserves all previous checklist runs; do not edit result lanes.
        write_json(ROOT / "Documentation/Testing/3.0-candidate.json", candidate)
    print(f"Signed development candidate: {app}")
    print(f"Identity: {candidate['id']}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"Candidate build failed: {error}")
