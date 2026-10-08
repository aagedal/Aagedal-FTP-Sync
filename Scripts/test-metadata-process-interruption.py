#!/usr/bin/env python3
"""Kill disposable publication test hosts, then verify recovery in fresh hosts.

First build with xcodebuild build-for-testing. Pass the resulting unit-test
.xctestrun file. Logs and fixture files stay in an ignored build directory.
This verifies process interruption, not power-loss durability or native UI.
"""
import argparse
import copy
import json
import itertools
import pathlib
import plistlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xctestrun", type=pathlib.Path)
    args = parser.parse_args()
    source = args.xctestrun.resolve()
    with source.open("rb") as stream:
        original = plistlib.load(stream)
    if "AagedalFTPSyncTests" not in original:
        parser.error("Expected a format-1 xctestrun containing AagedalFTPSyncTests")
    repository = pathlib.Path(__file__).resolve().parent.parent
    output = pathlib.Path(tempfile.mkdtemp(prefix="aagedal-interruption-", dir=repository / "build"))
    results = []
    print(f"Evidence directory: {output}", flush=True)
    for mode, media, phase in itertools.product(("ordinary", "managed"), ("jpeg", "raw-xmp"),
            ("prepared", "originalsHeld", "published-0", "beforeCommit")):
        case = f"{mode}-{media}-{phase}"
        fixture = output / f"aagedal-interruption-{case}"
        fixture.mkdir()
        configuration = copy.deepcopy(original)
        target = configuration["AagedalFTPSyncTests"]
        target.setdefault("EnvironmentVariables", {}).update({
            "AAGEDAL_INTERRUPTION_ROOT": str(fixture),
            "AAGEDAL_INTERRUPTION_PHASE": phase,
            "AAGEDAL_INTERRUPTION_MEDIA": media,
            "AAGEDAL_INTERRUPTION_MANAGED": "1" if mode == "managed" else "0",
        })
        # Keep beside the original so __TESTROOT__ retains its Xcode meaning.
        with tempfile.NamedTemporaryFile(suffix=".xctestrun", prefix="interruption-", dir=source.parent, delete=False) as stream:
            plistlib.dump(configuration, stream)
            configured = pathlib.Path(stream.name)
        try:
            for role, test in (("worker", "testProcessInterruptionWorker"), ("recovery", "testProcessInterruptionRecovery")):
                command = ["xcodebuild", "test-without-building", "-xctestrun", str(configured),
                           "-destination", "platform=macOS", "-parallel-testing-enabled", "NO",
                           "-only-testing:AagedalFTPSyncTests/LocalMatchingPublicationTests/" + test,
                           "-resultBundlePath", str(output / f"{case}-{role}.xcresult")]
                with (output / f"{case}-{role}.log").open("w") as log:
                    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180)
                marker = fixture / "inputs" / "interrupted-phase"
                reached = marker.is_file() and marker.read_text() == phase
                if role == "worker":
                    summary = json.loads(subprocess.check_output([
                        "xcrun", "xcresulttool", "get", "test-results", "summary", "--path",
                        str(output / f"{case}-{role}.xcresult"), "--format", "json"], timeout=30))
                    failures = summary.get("testFailures", [])
                    killed = any("signal 9" in failure.get("failureText", "").lower()
                                 or "signal kill" in failure.get("failureText", "").lower()
                                 or "sigkill" in failure.get("failureText", "").lower()
                                 for failure in failures)
                    if not killed:
                        raise RuntimeError(f"{case}: worker did not report SIGKILL: {failures}")
                    if result.returncode != 65 or not reached:
                        raise RuntimeError(f"{case}: expected killed worker (exit 65) with exact phase marker, got {result.returncode}")
                elif result.returncode != 0:
                    raise RuntimeError(f"{case}: fresh-process recovery failed ({result.returncode})")
                if role == "recovery":
                    verified = fixture / "inputs" / "recovery-verified"
                    if not verified.is_file() or verified.read_text() != phase:
                        raise RuntimeError(f"{case}: recovery test did not reach its final assertion")
                results.append({"mode": mode, "media": media, "phase": phase, "role": role, "exitCode": result.returncode})
                print(f"{case} {role}: expected exit {result.returncode}", flush=True)
                (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        finally:
            configured.unlink()
    print("PASS: all 16 JPEG and RAW/XMP interruptions recovered and admitted a fresh publication", flush=True)


if __name__ == "__main__":
    main()
