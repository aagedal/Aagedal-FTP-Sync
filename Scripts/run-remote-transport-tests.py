#!/usr/bin/env python3
"""Run opt-in loopback FTP, implicit FTPS, and SFTP integration tests."""

from __future__ import annotations

import json
import os
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
    "ftps": "FTPS-ROLLBACK.JPG",
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
    raise SystemExit("Timed out waiting for loopback FTP/FTPS/SFTP services")


def generate_ftps_identity(directory: Path) -> tuple[Path, Path, Path]:
    ca_configuration = directory / "ca.conf"
    ca_configuration.write_text(
        """[req]
distinguished_name = distinguished_name
x509_extensions = ca_extensions
prompt = no

[distinguished_name]
CN = Aagedal FTP Sync Loopback CA

[ca_extensions]
basicConstraints = critical,CA:true
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
""",
        encoding="utf-8",
    )
    server_configuration = directory / "server.conf"
    server_configuration.write_text(
        """[req]
distinguished_name = distinguished_name
req_extensions = server_extensions
prompt = no

[distinguished_name]
CN = localhost

[server_extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost
subjectKeyIdentifier = hash
""",
        encoding="utf-8",
    )
    ca_key = directory / "ca-key.pem"
    ca_certificate = directory / "ca-certificate.pem"
    ca_certificate_der = directory / "ca-certificate.der"
    server_key = directory / "server-key.pem"
    server_request = directory / "server.csr"
    server_certificate = directory / "server-certificate.pem"
    commands = [
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-days", "1", "-keyout", str(ca_key), "-out", str(ca_certificate),
            "-config", str(ca_configuration),
        ],
        [
            "openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(server_key), "-out", str(server_request),
            "-config", str(server_configuration),
        ],
        [
            "openssl", "x509", "-req", "-in", str(server_request),
            "-CA", str(ca_certificate), "-CAkey", str(ca_key), "-CAcreateserial",
            "-days", "1", "-out", str(server_certificate),
            "-extfile", str(server_configuration), "-extensions", "server_extensions",
        ],
        [
            "openssl", "x509", "-in", str(ca_certificate),
            "-outform", "DER", "-out", str(ca_certificate_der),
        ],
    ]
    for command in commands:
        try:
            subprocess.run(
                command,
                cwd=directory,
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
        except subprocess.CalledProcessError as error:
            details = error.stderr.strip() if error.stderr else "unknown error"
            raise SystemExit(f"Failed to generate the FTPS identity: {details}") from error
    return server_certificate, server_key, ca_certificate_der


def run_xcodebuild(configuration_path: Path) -> None:
    command = [
        "xcodebuild",
        "test",
        "-project",
        "Aagedal FTP Sync.xcodeproj",
        "-scheme",
        "AagedalFTPSync",
        "-destination",
        "platform=macOS",
        "-derivedDataPath",
        str(configuration_path.parent / "DerivedData"),
        "CODE_SIGNING_ALLOWED=NO",
        "-only-testing:AagedalFTPSyncTests/RemoteTransportIntegrationTests",
    ]
    process = subprocess.Popen(
        command,
        cwd=REPOSITORY_ROOT,
        env={
            **os.environ,
            "AFTPSYNC_REMOTE_TRANSPORT_CONFIG_PATH": str(configuration_path),
        },
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
    if shutil.which("openssl") is None:
        raise SystemExit("openssl is required")

    with tempfile.TemporaryDirectory(prefix="aftpsync-remote-transport-") as temporary:
        temporary_path = Path(temporary)
        certificate, private_key, trust_root = generate_ftps_identity(temporary_path)
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
                "--ftps-root",
                str(roots["ftps"]),
                "--sftp-root",
                str(roots["sftp"]),
                "--ftps-certificate",
                str(certificate),
                "--ftps-private-key",
                str(private_key),
                "--ready-file",
                str(ready_file),
                "--ftp-failure-path",
                FAILURE_FILES["ftp"],
                "--ftps-failure-path",
                FAILURE_FILES["ftps"],
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
                "AFTPSYNC_REMOTE_FTPS_HOST": "localhost",
                "AFTPSYNC_REMOTE_FTPS_PORT": str(ready["ftps_port"]),
                "AFTPSYNC_REMOTE_FTPS_TRUST_ROOT": str(trust_root),
                "AFTPSYNC_REMOTE_SFTP_PORT": str(ready["sftp_port"]),
                "AFTPSYNC_REMOTE_USERNAME": str(ready["username"]),
                "AFTPSYNC_REMOTE_PASSWORD": "integration",
                "AFTPSYNC_REMOTE_SFTP_FINGERPRINT": str(
                    ready["sftp_host_key_sha256"]
                ),
                "AFTPSYNC_REMOTE_FTP_ROOT": str(roots["ftp"]),
                "AFTPSYNC_REMOTE_FTPS_ROOT": str(roots["ftps"]),
                "AFTPSYNC_REMOTE_SFTP_ROOT": str(roots["sftp"]),
                "AFTPSYNC_REMOTE_FTP_FAILURE_FILE": FAILURE_FILES["ftp"],
                "AFTPSYNC_REMOTE_FTPS_FAILURE_FILE": FAILURE_FILES["ftps"],
                "AFTPSYNC_REMOTE_SFTP_FAILURE_FILE": FAILURE_FILES["sftp"],
                "AFTPSYNC_REMOTE_ORIGINAL_CONTENT": ORIGINAL_CONTENT,
            }
            configuration_path = temporary_path / "integration-configuration.json"
            configuration_path.write_text(
                json.dumps(configuration, sort_keys=True), encoding="utf-8"
            )
            run_xcodebuild(configuration_path)
            for protocol, root in roots.items():
                assert_fixture_clean(root, FAILURE_FILES[protocol])
        finally:
            service.terminate()
            try:
                service.wait(timeout=5)
            except subprocess.TimeoutExpired:
                service.kill()
                service.wait()

    print("FTP, trusted implicit FTPS, and SFTP integration tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
