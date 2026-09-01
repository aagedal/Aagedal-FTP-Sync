#!/usr/bin/env python3
"""Seed the 2.7 large tree, run loopback FTP/SFTP benchmarks, and write a report."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
SERVICE_SCRIPT = REPOSITORY_ROOT / "Scripts" / "delivery_latency_services.py"
DEFAULT_REPORT = REPOSITORY_ROOT / "Documentation" / "2.7-Delivery-Latency-Benchmark.md"
RESULT_PREFIX = "AFTPSYNC_BENCHMARK_RESULT "


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directories", type=int, default=100)
    parser.add_argument("--subdirectories", type=int, default=10)
    parser.add_argument("--files", type=int, default=100)
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    return parser.parse_args()


def require_positive(arguments: argparse.Namespace) -> None:
    for name in ("directories", "subdirectories", "files", "iterations"):
        if getattr(arguments, name) <= 0:
            raise SystemExit(f"--{name} must be positive")


def seed_tree(
    root: Path, directories: int, subdirectories: int, files: int
) -> tuple[int, str]:
    old_timestamp = 946_684_800
    newest_path = "DIR_000/SUB_000/IMG_000.JPG"
    total = 0
    for directory_index in range(directories):
        for subdirectory_index in range(subdirectories):
            folder = root / f"DIR_{directory_index:03d}" / f"SUB_{subdirectory_index:03d}"
            folder.mkdir(parents=True)
            for file_index in range(files):
                name = f"IMG_{file_index:03d}.JPG"
                if (
                    directory_index == directories - 1
                    and subdirectory_index == subdirectories - 1
                    and files >= 2
                    and file_index == files - 2
                ):
                    name = "COLLISION.CR2"
                elif (
                    directory_index == directories - 1
                    and subdirectory_index == subdirectories - 1
                    and files >= 2
                    and file_index == files - 1
                ):
                    name = "COLLISION.NEF"
                path = folder / name
                path.touch()
                os.utime(path, (old_timestamp, old_timestamp))
                total += 1

    newest = root / newest_path
    if not newest.exists():
        newest = next(root.rglob("*.JPG"))
        newest_path = newest.relative_to(root).as_posix()
    now = time.time()
    os.utime(newest, (now, now))
    return total, newest_path


def wait_for_services(process: subprocess.Popen[str], ready_file: Path) -> dict[str, object]:
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if ready_file.exists():
            return json.loads(ready_file.read_text(encoding="utf-8"))
        if process.poll() is not None:
            output = process.stdout.read() if process.stdout else ""
            raise SystemExit(f"Loopback services exited before becoming ready:\n{output}")
        time.sleep(0.1)
    process.terminate()
    raise SystemExit("Timed out waiting for loopback FTP/SFTP services")


def run_xcodebuild() -> tuple[dict[str, object], str]:
    command = [
        "xcodebuild",
        "test",
        "-project",
        "Aagedal FTP Sync.xcodeproj",
        "-scheme",
        "AagedalFTPSync",
        "-destination",
        "platform=macOS",
        "CODE_SIGNING_ALLOWED=NO",
        "-only-testing:AagedalFTPSyncTests/DeliveryLatencyBenchmarkTests/testLargeTreeBenchmark",
    ]
    process = subprocess.Popen(
        command,
        cwd=REPOSITORY_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    output_lines: list[str] = []
    payload: dict[str, object] | None = None
    assert process.stdout is not None
    for line in process.stdout:
        output_lines.append(line)
        if (
            RESULT_PREFIX in line
            or "Test Case" in line
            or line.startswith("** TEST")
            or " error: " in line
        ):
            print(line, end="")
        marker = line.find(RESULT_PREFIX)
        if marker >= 0:
            payload = json.loads(line[marker + len(RESULT_PREFIX) :])
    return_code = process.wait()
    output = "".join(output_lines)
    if return_code != 0:
        print(output, file=sys.stderr)
        raise SystemExit(return_code)
    if payload is None:
        raise SystemExit("Benchmark test succeeded without emitting a result payload")
    return payload, output


def hardware_summary() -> str:
    details = [platform.platform(), platform.machine()]
    try:
        output = subprocess.check_output(
            ["system_profiler", "SPHardwareDataType"], text=True, timeout=15
        )
        for label in ("Model Name", "Chip", "Memory"):
            for line in output.splitlines():
                if line.strip().startswith(label + ":"):
                    details.append(line.strip())
                    break
    except (OSError, subprocess.SubprocessError):
        pass
    return "; ".join(details)


def xcode_version() -> str:
    try:
        return " / ".join(
            subprocess.check_output(["xcodebuild", "-version"], text=True)
            .strip()
            .splitlines()
        )
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def service_versions() -> str:
    versions = []
    for package in ("pyftpdlib", "paramiko"):
        try:
            versions.append(f"{package} {importlib.metadata.version(package)}")
        except importlib.metadata.PackageNotFoundError:
            versions.append(f"{package} unknown")
    return ", ".join(versions)


def write_report(
    report_path: Path,
    payload: dict[str, object],
    arguments: argparse.Namespace,
    traversal_directories: int,
) -> None:
    rows = []
    for result in payload["results"]:
        assert isinstance(result, dict)
        for state, key in (
            ("Cold", "coldFullScan"),
            ("Warm", "warmFullScan"),
            ("Cold", "coldFirstPublication"),
            ("Warm", "warmFirstPublication"),
        ):
            metric = "Full scan" if "FullScan" in key else "First publication"
            summary = result[key]
            rows.append(
                f"| {str(result['protocolName']).upper()} | {state} | {metric} | "
                f"{summary['median']:.3f} | {summary['p95']:.3f} |"
            )

    timestamp = time.strftime("%Y-%m-%d %H:%M:%S %Z")
    report = f"""# Aagedal FTP Sync 2.7 delivery-latency benchmark

Recorded {timestamp} on `{hardware_summary()}` with `{xcode_version()}` using the Debug configuration.

## Fixture and method

- Loopback FTP and SFTP services exposed the same fixed tree: {arguments.directories} top-level directories × {arguments.subdirectories} subdirectories × {arguments.files} zero-byte files ({payload['expectedFiles']:,} files; {traversal_directories:,} directories including the root).
- Service fixture versions: {service_versions()}.
- One JPEG had a current modification date and all other files used 2000-01-01. The sync job's one-hour recent-file filter therefore published exactly one file.
- Each cell used one unrecorded warm-up and {payload['iterations']} measured iterations. Cold means a new protocol connection for each iteration; warm means a reused authenticated connection. Both states benefit from the host filesystem cache after warm-up.
- Full scan measures `EndpointSession.listFiles()`. First publication measures a complete `SyncEngine.run`, ending after the newest file was downloaded and accepted by the destination.
- The current engine waits for the authoritative full listing before publication. These numbers are a 2.7 baseline, not a measurement of the completed-directory design.

## Results (seconds)

| Protocol | Connection | Metric | Median | p95 |
|---|---|---|---:|---:|
{os.linesep.join(rows)}

With five samples, p95 is the slowest observed iteration (nearest-rank method). Loopback absolute timings are informational and should be compared only with runs using the same fixture and build configuration.
"""
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(report, encoding="utf-8")


def main() -> int:
    arguments = parse_arguments()
    require_positive(arguments)
    if shutil.which("xcodebuild") is None:
        raise SystemExit("xcodebuild is required")

    with tempfile.TemporaryDirectory(prefix="aftpsync-delivery-benchmark-") as temporary:
        temporary_path = Path(temporary)
        root = temporary_path / "tree"
        root.mkdir()
        print("Seeding benchmark tree…", flush=True)
        expected_files, newest_path = seed_tree(
            root, arguments.directories, arguments.subdirectories, arguments.files
        )
        ready_file = temporary_path / "services.json"
        service = subprocess.Popen(
            [
                sys.executable,
                str(SERVICE_SCRIPT),
                "--root",
                str(root),
                "--ready-file",
                str(ready_file),
                "--ftp-port",
                "0",
                "--sftp-port",
                "0",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            ready = wait_for_services(service, ready_file)
            configuration = {
                    "AFTPSYNC_RUN_DELIVERY_BENCHMARK": "1",
                    "AFTPSYNC_BENCHMARK_ITERATIONS": str(arguments.iterations),
                    "AFTPSYNC_BENCHMARK_FILE_COUNT": str(expected_files),
                    "AFTPSYNC_BENCHMARK_NEWEST_PATH": newest_path,
                    "AFTPSYNC_BENCHMARK_HOST": str(ready["host"]),
                    "AFTPSYNC_BENCHMARK_FTP_PORT": str(ready["ftp_port"]),
                    "AFTPSYNC_BENCHMARK_SFTP_PORT": str(ready["sftp_port"]),
                    "AFTPSYNC_BENCHMARK_USERNAME": str(ready["username"]),
                    "AFTPSYNC_BENCHMARK_PASSWORD": "benchmark",
                    "AFTPSYNC_BENCHMARK_SFTP_FINGERPRINT": str(
                        ready["sftp_host_key_sha256"]
                    ),
                    "AFTPSYNC_BENCHMARK_REMOTE_PATH": "/",
                }
            configuration_path = temporary_path / "benchmark-configuration.json"
            configuration_path.write_text(
                json.dumps(configuration, sort_keys=True), encoding="utf-8"
            )
            payload, _ = run_xcodebuild()
        finally:
            service.terminate()
            try:
                service.wait(timeout=5)
            except subprocess.TimeoutExpired:
                service.kill()
                service.wait()

    traversal_directories = 1 + arguments.directories + (
        arguments.directories * arguments.subdirectories
    )
    write_report(arguments.report.resolve(), payload, arguments, traversal_directories)
    print(f"Wrote {arguments.report.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
