#!/usr/bin/env python3
"""Exercise durable results, concurrency rejection, and loopback write boundaries."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from urllib.error import HTTPError
from urllib.parse import urlsplit, parse_qs
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]


class ChecklistTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state_path = Path(self.temp.name) / 'results.json'
        self.start()

    def start(self):
        self.process = subprocess.Popen([sys.executable, str(ROOT / 'Scripts/serve-3.0-checklist.py'), '--no-open', '--port', '0', '--state', str(self.state_path)], stdout=subprocess.PIPE, text=True)
        url = self.process.stdout.readline().strip().removeprefix('Checklist: ')
        parts = urlsplit(url)
        self.base = f'{parts.scheme}://{parts.netloc}'
        self.token = parse_qs(parts.fragment)['token'][0]

    def stop(self):
        self.process.terminate()
        self.process.wait(timeout=5)
        self.process.stdout.close()

    def tearDown(self):
        self.stop()
        self.temp.cleanup()

    def request(self, path, payload=None, token=True, origin=True):
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['X-Checklist-Token'] = self.token
        if origin:
            headers['Origin'] = self.base
        req = Request(self.base + path, data=json.dumps(payload).encode() if payload is not None else None, headers=headers)
        try:
            with urlopen(req) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            with error:
                return error.code, json.load(error)

    def payload(self):
        _, data = self.request('/api/state')
        return {'revision': data['state']['revision'], 'candidate': data['candidate']['id'], 'id': data['catalog']['cases'][0]['id'], 'actor': 'agent', 'status': 'passed', 'notes': 'Synthetic server test, never production evidence.', 'environment': 'Temporary state file only'}

    def test_persistence_separation_and_conflicts(self):
        item = self.payload()
        self.assertEqual(self.request('/api/result', item)[0], 200)
        self.assertEqual(self.request('/api/result', item)[0], 409)
        item['revision'] = 1
        item['actor'] = 'user'
        item['status'] = 'blocked'
        self.assertEqual(self.request('/api/result', item)[0], 200)
        self.stop()
        self.start()
        _, data = self.request('/api/state')
        run = data['state']['runs'][item['candidate']]
        self.assertEqual(run['agent'][item['id']]['status'], 'passed')
        self.assertEqual(run['user'][item['id']]['status'], 'blocked')
        self.assertEqual(len(run['history']), 2)
        self.assertEqual(data['state']['revision'], 2)

    def test_reject_unauthorized_and_invalid_without_writes(self):
        item = self.payload()
        self.assertEqual(self.request('/api/state', token=False)[0], 403)
        self.assertEqual(self.request('/api/result', item, token=False)[0], 403)
        self.assertEqual(self.request('/api/result', item, origin=False)[0], 403)
        item['status'] = 'waived'
        self.assertEqual(self.request('/api/result', item)[0], 400)
        item['status'] = 'passed'
        item['notes'] = ''
        self.assertEqual(self.request('/api/result', item)[0], 400)
        item['notes'] = 'evidence'
        item['candidate'] = 'stale-candidate'
        self.assertEqual(self.request('/api/result', item)[0], 409)
        self.assertFalse(self.state_path.exists())

    def test_corrupt_state_is_preserved(self):
        self.state_path.write_text('{broken')
        self.assertEqual(self.request('/api/state')[0], 500)
        self.assertEqual(self.state_path.read_text(), '{broken')

    def test_agent_cannot_record_final_user_acceptance(self):
        item = self.payload()
        item['id'] = 'm6-004'
        self.assertEqual(self.request('/api/result', item)[0], 400)
        self.assertFalse(self.state_path.exists())

    def test_second_server_cannot_write_same_state(self):
        result = subprocess.run([sys.executable, str(ROOT / 'Scripts/serve-3.0-checklist.py'), '--no-open', '--port', '0', '--state', str(self.state_path)], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already using this results file', result.stderr)


if __name__ == '__main__':
    unittest.main()
