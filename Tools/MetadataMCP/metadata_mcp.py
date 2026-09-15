#!/usr/bin/env python3
"""Local stdio MCP adapter for the running Aagedal FTP Sync app."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import time
import uuid


SERVER_NAME = "aagedal-metadata"
PROTOCOL_VERSION = "2025-11-25"
COMPATIBLE_VERSIONS = {"2024-11-05", "2025-03-26", "2025-06-18", PROTOCOL_VERSION}
REQUEST_TIMEOUT = 30.0


def object_schema(properties: dict, required: list[str] | None = None) -> dict:
    return {
        "type": "object",
        "properties": properties,
        "required": required or [],
        "additionalProperties": False,
    }


TEXT = {"type": "string"}
UUID = {"type": "string", "format": "uuid"}
TIMESTAMP = {
    "type": "string",
    "format": "date-time",
    "description": "ISO 8601 timestamp including a time zone, for example 2026-09-15T13:00:00+02:00.",
}

TOOLS = [
    {
        "name": "fetch_jobs",
        "description": "List saved jobs with IDs, metadata counts, draft status, and shared-calendar IDs.",
        "inputSchema": object_schema({}),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "fetch_photographers",
        "description": "List the shared photographer library, or photographers assigned to one job.",
        "inputSchema": object_schema({"job_id": UUID}),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "add_photographer",
        "description": "Add a new photographer to a job and the shared library. The job's open metadata draft must be saved first.",
        "inputSchema": object_schema(
            {
                "job_id": UUID,
                "name": TEXT,
                "filename_initials": {
                    "type": "string",
                    "description": "Comma-separated camera filename initials; these must be unique across photographers.",
                },
                "copyright_notice": TEXT,
            },
            ["job_id", "name", "filename_initials"],
        ),
        "annotations": {"readOnlyHint": False},
    },
    {
        "name": "fetch_metadata_clips",
        "description": "List saved metadata clips for a job. Optional bounds select clips that overlap the interval.",
        "inputSchema": object_schema(
            {"job_id": UUID, "ends_after": TIMESTAMP, "starts_before": TIMESTAMP}, ["job_id"]
        ),
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "add_metadata_clip",
        "description": "Add a clip to a job and create its day tracks. Rejects overlap and other validation errors.",
        "inputSchema": object_schema(
            {
                "job_id": UUID,
                "photographer_id": UUID,
                "name": TEXT,
                "starts_at": TIMESTAMP,
                "ends_at": TIMESTAMP,
                "headline": TEXT,
                "description": TEXT,
                "keywords": {"type": "array", "items": TEXT},
                "gps": object_schema(
                    {
                        "latitude": {"type": "number", "minimum": -90, "maximum": 90},
                        "longitude": {"type": "number", "minimum": -180, "maximum": 180},
                        "altitude_meters": {"type": "number"},
                        "label": TEXT,
                    },
                    ["latitude", "longitude"],
                ),
            },
            ["job_id", "photographer_id", "name", "starts_at", "ends_at"],
        ),
        "annotations": {"readOnlyHint": False},
    },
]

TOOL_NAMES = {tool["name"] for tool in TOOLS}


def bridge_directory() -> Path:
    override = os.environ.get("AAGEDAL_MCP_BRIDGE_DIR")
    if override:
        candidate = Path(override).expanduser()
        if not candidate.is_absolute():
            raise ValueError("AAGEDAL_MCP_BRIDGE_DIR must be an absolute path")
        return candidate
    candidates = [
        Path.home()
        / "Library/Containers/no.aagedal.AagedalFTPSync/Data/Library/Application Support/AagedalFTPSync/v3/mcp-bridge",
        Path.home() / "Library/Application Support/AagedalFTPSync/v3/mcp-bridge",
    ]
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    raise RuntimeError("Open Aagedal FTP Sync with admitted v3 storage, then retry the MCP tool")


def call_app(tool: str, arguments: dict) -> object:
    directory = bridge_directory()
    requests = directory / "requests"
    responses = directory / "responses"
    if not requests.is_dir() or not responses.is_dir():
        raise RuntimeError("The app's metadata MCP bridge is not running")
    request_id = str(uuid.uuid4()).upper()
    request_path = requests / f"{request_id}.json"
    temp_path = requests / f".{request_id}.tmp"
    response_path = responses / f"{request_id}.json"
    request = {
        "id": request_id,
        "tool": tool,
        "arguments": arguments,
        "expires_at": time.time() + REQUEST_TIMEOUT,
    }
    data = json.dumps(request, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(data) > 65_536:
        raise ValueError("The tool arguments are too large")
    try:
        fd = os.open(temp_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp_path, request_path)
        deadline = time.monotonic() + REQUEST_TIMEOUT
        while time.monotonic() < deadline:
            try:
                response = json.loads(response_path.read_text(encoding="utf-8"))
            except FileNotFoundError:
                time.sleep(0.1)
                continue
            if response.get("ok") is not True:
                raise RuntimeError(response.get("error", "The app rejected the metadata request"))
            return response["data"]
        raise TimeoutError(
            "The app did not answer in 30 seconds. If this was an add operation, "
            "fetch the records before retrying because the save may have completed."
        )
    finally:
        temp_path.unlink(missing_ok=True)
        response_path.unlink(missing_ok=True)
        # If the app has not picked this up, prevent a late write after timeout.
        request_path.unlink(missing_ok=True)


def response(request_id: object, result: dict | None = None, error: dict | None = None) -> dict:
    message = {"jsonrpc": "2.0", "id": request_id}
    if error is not None:
        message["error"] = error
    else:
        message["result"] = result
    return message


def handle(message: object) -> dict | None:
    if not isinstance(message, dict):
        return response(None, error={"code": -32600, "message": "Invalid request"})
    method = message.get("method")
    request_id = message.get("id")
    if request_id is None:
        return None  # Client notification.
    if method == "initialize":
        params = message.get("params")
        requested_version = params.get("protocolVersion") if isinstance(params, dict) else None
        return response(
            request_id,
            result={
                "protocolVersion": requested_version
                if isinstance(requested_version, str) and requested_version in COMPATIBLE_VERSIONS
                else PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": "0.1.0"},
            },
        )
    if method == "ping":
        return response(request_id, result={})
    if method == "tools/list":
        return response(request_id, result={"tools": TOOLS})
    if method == "tools/call":
        params = message.get("params")
        name = params.get("name") if isinstance(params, dict) else None
        if not isinstance(name, str) or name not in TOOL_NAMES:
            return response(request_id, error={"code": -32602, "message": "Unknown tool"})
        arguments = params.get("arguments", {})
        if not isinstance(arguments, dict):
            return response(request_id, error={"code": -32602, "message": "arguments must be an object"})
        try:
            data = call_app(params["name"], arguments)
            return response(
                request_id,
                result={"content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False)}]},
            )
        except (OSError, RuntimeError, TimeoutError, ValueError, KeyError) as exc:
            return response(
                request_id,
                result={"content": [{"type": "text", "text": str(exc)}], "isError": True},
            )
    return response(request_id, error={"code": -32601, "message": f"Unknown method: {method}"})


def main() -> None:
    for line in sys.stdin:
        try:
            message = handle(json.loads(line))
        except json.JSONDecodeError:
            message = response(None, error={"code": -32700, "message": "Invalid JSON"})
        if message is not None:
            sys.stdout.write(json.dumps(message, separators=(",", ":"), ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
