#!/usr/bin/env python3
"""Serve writable loopback FTP and SFTP roots with deterministic publish faults."""

from __future__ import annotations

import argparse
import base64
import errno
import hashlib
import hmac
import json
import os
from pathlib import Path
import posixpath
import queue
import signal
import socket
import sys
import threading

try:
    import paramiko
    from pyftpdlib.authorizers import DummyAuthorizer
    from pyftpdlib.handlers import FTPHandler
    from pyftpdlib.servers import FTPServer
except ImportError as error:
    raise SystemExit(
        "remote_transport_services.py requires pyftpdlib and paramiko; "
        "install the pinned versions from Scripts/delivery-latency-requirements.txt"
    ) from error


class PasswordServer(paramiko.ServerInterface):
    def __init__(self, username: str, password: str) -> None:
        self.username = username
        self.password = password

    def check_auth_password(self, username: str, password: str) -> int:
        if hmac.compare_digest(username, self.username) and hmac.compare_digest(
            password, self.password
        ):
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def get_allowed_auths(self, username: str) -> str:
        return "password"

    def check_channel_request(self, kind: str, chanid: int) -> int:
        if kind == "session":
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED


class WritableSFTPServer(paramiko.SFTPServerInterface):
    """Filesystem-backed SFTP server confined to one root."""

    def __init__(
        self,
        server: object,
        *,
        root: Path,
        publication_failure_path: str,
    ) -> None:
        super().__init__(server)
        self.root = root.resolve()
        self.publication_failure_path = self._local_path(publication_failure_path)

    def _local_path(self, path: str) -> Path:
        if "\0" in path:
            raise OSError(errno.EINVAL, "NUL in path")
        virtual = posixpath.normpath("/" + path.lstrip("/"))
        candidate = self.root.joinpath(*virtual.lstrip("/").split("/")).resolve()
        try:
            common = os.path.commonpath((str(self.root), str(candidate)))
        except ValueError as error:
            raise PermissionError(errno.EACCES, "path escapes integration root") from error
        if common != str(self.root):
            raise PermissionError(errno.EACCES, "path escapes integration root")
        return candidate

    @staticmethod
    def _status(error: OSError) -> int:
        return paramiko.SFTPServer.convert_errno(error.errno or 1)

    @staticmethod
    def _is_staged_part(path: Path) -> bool:
        return path.name.startswith(".aagedal-sync-") and path.name.endswith(".part")

    def canonicalize(self, path: str) -> str:
        virtual = posixpath.normpath("/" + path.lstrip("/"))
        self._local_path(virtual)
        return virtual

    def list_folder(self, path: str):
        try:
            local = self._local_path(path)
            return [
                paramiko.SFTPAttributes.from_stat(
                    os.lstat(local / name), filename=name
                )
                for name in os.listdir(local)
            ]
        except OSError as error:
            return self._status(error)

    def stat(self, path: str):
        try:
            return paramiko.SFTPAttributes.from_stat(os.stat(self._local_path(path)))
        except OSError as error:
            return self._status(error)

    def lstat(self, path: str):
        try:
            return paramiko.SFTPAttributes.from_stat(os.lstat(self._local_path(path)))
        except OSError as error:
            return self._status(error)

    def open(self, path: str, flags: int, attr: object):
        try:
            local = self._local_path(path)
            descriptor = os.open(local, flags, 0o600)
            if flags & os.O_RDWR:
                mode = "a+b" if flags & os.O_APPEND else "r+b"
            elif flags & os.O_WRONLY:
                mode = "ab" if flags & os.O_APPEND else "wb"
            else:
                mode = "rb"
            file_object = os.fdopen(descriptor, mode)
            if attr is not None:
                paramiko.SFTPServer.set_file_attr(str(local), attr)
        except OSError as error:
            return self._status(error)

        handle = paramiko.SFTPHandle(flags)
        if not flags & os.O_WRONLY:
            handle.readfile = file_object
        if flags & (os.O_WRONLY | os.O_RDWR):
            handle.writefile = file_object
        return handle

    def mkdir(self, path: str, attr: object):
        try:
            local = self._local_path(path)
            os.mkdir(local, mode=getattr(attr, "st_mode", None) or 0o700)
            if attr is not None:
                paramiko.SFTPServer.set_file_attr(str(local), attr)
            return paramiko.SFTP_OK
        except OSError as error:
            return self._status(error)

    def remove(self, path: str):
        try:
            os.remove(self._local_path(path))
            return paramiko.SFTP_OK
        except OSError as error:
            return self._status(error)

    def rename(self, oldpath: str, newpath: str):
        try:
            source = self._local_path(oldpath)
            destination = self._local_path(newpath)
            if self._is_staged_part(source) and destination == self.publication_failure_path:
                return paramiko.SFTP_FAILURE
            os.rename(source, destination)
            return paramiko.SFTP_OK
        except OSError as error:
            return self._status(error)

    def chattr(self, path: str, attr: object):
        try:
            paramiko.SFTPServer.set_file_attr(str(self._local_path(path)), attr)
            return paramiko.SFTP_OK
        except OSError as error:
            return self._status(error)


class SFTPService:
    def __init__(
        self,
        host: str,
        port: int,
        root: Path,
        username: str,
        password: str,
        host_key: paramiko.PKey,
        publication_failure_path: str,
        stop: threading.Event,
        failures: queue.Queue[BaseException],
    ) -> None:
        self.root = root
        self.username = username
        self.password = password
        self.host_key = host_key
        self.publication_failure_path = publication_failure_path
        self.stop = stop
        self.failures = failures
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind((host, port))
        self.socket.listen(16)
        self.socket.settimeout(0.5)
        self.port = self.socket.getsockname()[1]
        self._transports: set[paramiko.Transport] = set()
        self._lock = threading.Lock()

    def serve(self) -> None:
        try:
            while not self.stop.is_set():
                try:
                    client, _ = self.socket.accept()
                except socket.timeout:
                    continue
                except OSError:
                    if self.stop.is_set():
                        return
                    raise
                threading.Thread(
                    target=self._serve_client, args=(client,), daemon=True
                ).start()
        except BaseException as error:
            self.failures.put(error)
            self.stop.set()

    def _serve_client(self, client: socket.socket) -> None:
        transport = paramiko.Transport(client)
        with self._lock:
            self._transports.add(transport)
        try:
            transport.add_server_key(self.host_key)
            transport.set_subsystem_handler(
                "sftp",
                paramiko.SFTPServer,
                WritableSFTPServer,
                root=self.root,
                publication_failure_path=self.publication_failure_path,
            )
            transport.start_server(
                server=PasswordServer(self.username, self.password)
            )
            while transport.is_active() and not self.stop.wait(0.25):
                pass
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            transport.close()
            client.close()
            with self._lock:
                self._transports.discard(transport)

    def close(self) -> None:
        self.socket.close()
        with self._lock:
            for transport in tuple(self._transports):
                transport.close()


def make_ftp_handler(root: Path, publication_failure_path: str):
    failed_destination = (root / publication_failure_path).resolve()

    class FaultInjectingFTPHandler(FTPHandler):
        def ftp_RNTO(self, path: str):
            source_text = getattr(self, "_rnfr", None)
            if source_text is not None:
                source = Path(source_text)
                destination = Path(path).resolve()
                if (
                    source.name.startswith(".aagedal-sync-")
                    and source.name.endswith(".part")
                    and destination == failed_destination
                ):
                    self._rnfr = None
                    self.respond("550 Injected publication failure.")
                    return
            return super().ftp_RNTO(path)

    return FaultInjectingFTPHandler


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ftp-root", required=True, type=Path)
    parser.add_argument("--sftp-root", required=True, type=Path)
    parser.add_argument("--ready-file", required=True, type=Path)
    parser.add_argument("--host", choices=("127.0.0.1", "localhost"), default="127.0.0.1")
    parser.add_argument("--ftp-port", type=int, default=0)
    parser.add_argument("--sftp-port", type=int, default=0)
    parser.add_argument("--username", default="integration")
    parser.add_argument("--password", default="integration")
    parser.add_argument("--ftp-failure-path", default="FTP-ROLLBACK.JPG")
    parser.add_argument("--sftp-failure-path", default="SFTP-ROLLBACK.JPG")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    ftp_root = arguments.ftp_root.resolve()
    sftp_root = arguments.sftp_root.resolve()
    if not ftp_root.is_dir() or not sftp_root.is_dir():
        raise SystemExit("FTP and SFTP integration roots must already exist")

    stop = threading.Event()
    failures: queue.Queue[BaseException] = queue.Queue()
    host_key = paramiko.ECDSAKey.generate()

    authorizer = DummyAuthorizer()
    authorizer.add_user(
        arguments.username,
        arguments.password,
        str(ftp_root),
        perm="elradfmwMT",
    )
    ftp_handler = make_ftp_handler(ftp_root, arguments.ftp_failure_path)
    ftp_handler.authorizer = authorizer
    ftp_server = FTPServer((arguments.host, arguments.ftp_port), ftp_handler)

    sftp_service = SFTPService(
        arguments.host,
        arguments.sftp_port,
        sftp_root,
        arguments.username,
        arguments.password,
        host_key,
        arguments.sftp_failure_path,
        stop,
        failures,
    )

    def serve_ftp() -> None:
        try:
            ftp_server.serve_forever(timeout=0.5, blocking=True, handle_exit=False)
        except BaseException as error:
            if not stop.is_set():
                failures.put(error)
                stop.set()

    threads = [
        threading.Thread(target=serve_ftp, name="ftp-integration-server", daemon=True),
        threading.Thread(target=sftp_service.serve, name="sftp-integration-server", daemon=True),
    ]
    for thread in threads:
        thread.start()

    fingerprint = "SHA256:" + base64.b64encode(
        hashlib.sha256(host_key.asbytes()).digest()
    ).decode("ascii").rstrip("=")
    ready = {
        "host": arguments.host,
        "ftp_port": ftp_server.socket.getsockname()[1],
        "sftp_port": sftp_service.port,
        "username": arguments.username,
        "sftp_host_key_sha256": fingerprint,
    }
    arguments.ready_file.parent.mkdir(parents=True, exist_ok=True)
    temporary_ready = arguments.ready_file.with_name(arguments.ready_file.name + ".tmp")
    temporary_ready.write_text(json.dumps(ready, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary_ready, arguments.ready_file)

    def request_stop(signum: int, frame: object) -> None:
        stop.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    failure: BaseException | None = None
    while not stop.wait(0.25):
        try:
            failure = failures.get_nowait()
        except queue.Empty:
            continue
        stop.set()

    ftp_server.close_all()
    sftp_service.close()
    for thread in threads:
        thread.join(timeout=3)

    if failure is not None:
        print(f"loopback integration service failed: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
