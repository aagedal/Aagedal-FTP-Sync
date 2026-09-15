import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import metadata_mcp


class MetadataMCPTests(unittest.TestCase):
    def test_initialize_and_five_tools(self):
        initialized = metadata_mcp.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                           "params": {"protocolVersion": "2025-06-18"}})
        self.assertEqual(initialized["result"]["capabilities"], {"tools": {}})
        self.assertEqual(initialized["result"]["protocolVersion"], "2025-06-18")
        listed = metadata_mcp.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        self.assertEqual(
            [tool["name"] for tool in listed["result"]["tools"]],
            ["fetch_jobs", "fetch_photographers", "add_photographer", "fetch_metadata_clips", "add_metadata_clip"],
        )

    def test_tool_call_uses_private_queue_and_returns_app_result(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "requests").mkdir()
            (directory / "responses").mkdir()
            observed = []

            def app_worker():
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    files = list((directory / "requests").glob("*.json"))
                    if files:
                        request = json.loads(files[0].read_text())
                        observed.append(request)
                        (directory / "responses" / files[0].name).write_text(
                            json.dumps({"ok": True, "data": [{"id": "job-1"}]})
                        )
                        return
                    time.sleep(0.01)

            worker = threading.Thread(target=app_worker)
            worker.start()
            with patch.dict(os.environ, {"AAGEDAL_MCP_BRIDGE_DIR": str(directory)}):
                result = metadata_mcp.handle(
                    {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                     "params": {"name": "fetch_jobs", "arguments": {}}}
                )
            worker.join(timeout=3)
            self.assertEqual(json.loads(result["result"]["content"][0]["text"]), [{"id": "job-1"}])
            self.assertEqual(observed[0]["tool"], "fetch_jobs")
            self.assertFalse(list((directory / "requests").glob("*.json")))
            self.assertFalse(list((directory / "responses").glob("*.json")))


if __name__ == "__main__":
    unittest.main()
