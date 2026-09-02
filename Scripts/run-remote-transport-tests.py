#!/usr/bin/env python3
"""Run opt-in loopback FTP and SFTP write/fault integration tests."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
SERVICE_SCRIPT = REPOSITORY_ROOT / "Scripts" / "remote_transport_services.py"
FAILURE_FILES = {
    "ftp": "FTP-ROLLBACK.JPG",
    "sftp": "SFTP-ROLLBACK.JPG",
}
ORIGINAL_CONTENT = "published-before-fault\n"


def wait_for_services(
    process: subprocess.Popen[str], ready_file: Path
) -> dict[str, object]:
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


def run_xcodebuild() -> None:
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
        "-only-testing:AagedalFTPSyncTests/RemoteTransportIntegrationTests",
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
    assert process.stdout is not None
    for line in process.stdout:
        output_lines.append(line)
        if "Test Case" in line or line.startswith("** TEST") or " error: " in line:
            print(line, end="")
    return_code = process.wait()
    if return_code != 0:
        print("".join(output_lines), file=sys.stderr)
        raise SystemExit(return_code)


def assert_fixture_clean(root: Path, failure_file: str) -> None:
    failure_path = root / failure_file
    if failure_path.read_text(encoding="utf-8") != ORIGINAL_CONTENT:
        raise SystemExit(f"Fault test changed the previously published file: {failure_path}")
    staging = [
        path
        for path in root.rglob("*")
        if path.name.startswith(".aagedal-sync-")
    ]
    if staging:
        raise SystemExit(
            "Fault test left internal staging files behind: "
            + ", ".join(str(path) for path in staging)
        )


def main() -> int:
    if shutil.which("xcodebuild") is None:
        raise SystemExit("xcodebuild is required")

    with tempfile.TemporaryDirectory(prefix="aftpsync-remote-transport-") as temporary:
        temporary_path = Path(temporary)
        roots = {
            protocol: temporary_path / f"{protocol}-root"
            for protocol in FAILURE_FILES
        }
        for protocol, root in roots.items():
            root.mkdir()
            (root / FAILURE_FILES[protocol]).write_text(
                ORIGINAL_CONTENT, encoding="utf-8"
            )

        ready_file = temporary_path / "services.json"
        service = subprocess.Popen(
            [
                sys.executable,
                str(SERVICE_SCRIPT),
                "--ftp-root",
                str(roots["ftp"]),
                "--sftp-root",
                str(roots["sftp"]),
                "--ready-file",
                str(ready_file),
                "--ftp-failure-path",
                FAILURE_FILES["ftp"],
                "--sftp-failure-path",
                FAILURE_FILES["sftp"],
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            ready = wait_for_services(service, ready_file)
            configuration = {
                "AFTPSYNC_RUN_REMOTE_TRANSPORT_TESTS": "1",
                "AFTPSYNC_REMOTE_HOST": str(ready["host"]),
                "AFTPSYNC_REMOTE_FTP_PORT": str(ready["ftp_port"]),
                "AFTPSYNC_REMOTE_SFTP_PORT": str(ready["sftp_port"]),
                "AFTPSYNC_REMOTE_USERNAME": str(ready["username"]),
                "AFTPSYNC_REMOTE_PASSWORD": "integration",
                "AFTPSYNC_REMOTE_SFTP_FINGERPRINT": str(
                    ready["sftp_host_key_sha256"]
                ),
                "AFTPSYNC_REMOTE_FTP_ROOT": str(roots["ftp"]),
                "AFTPSYNC_REMOTE_SFTP_ROOT": str(roots["sftp"]),
                "AFTPSYNC_REMOTE_FTP_FAILURE_FILE": FAILURE_FILES["ftp"],
                "AFTPSYNC_REMOTE_SFTP_FAILURE_FILE": FAILURE_FILES["sftp"],
                "AFTPSYNC_REMOTE_ORIGINAL_CONTENT": ORIGINAL_CONTENT,
            }
            (temporary_path / "integration-configuration.json").write_text(
                json.dumps(configuration, sort_keys=True), encoding="utf-8"
            )
            run_xcodebuild()
            for protocol, root in roots.items():
                assert_fixture_clean(root, FAILURE_FILES[protocol])
        finally:
            service.terminate()
            try:
                service.wait(timeout=5)
            except subprocess.TimeoutExpired:
                service.kill()
                service.wait()

    print("FTP and SFTP write/fault integration tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
