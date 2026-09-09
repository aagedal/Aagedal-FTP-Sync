#!/usr/bin/env python3
"""Loopback-only manual-test checklist. Results are durable JSON, never browser-only."""
import argparse
import fcntl
import hmac
import json
import os
from pathlib import Path
import secrets
import tempfile
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
import webbrowser

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / 'Documentation' / 'Testing'
STATUSES = {'not_run', 'passed', 'failed', 'blocked'}


def read_json(path):
    return json.loads(path.read_text())


def atomic_write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.checklist-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, indent=2, ensure_ascii=False)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8763)
    parser.add_argument('--no-open', action='store_true')
    parser.add_argument('--state', type=Path, default=DOCS / '3.0-results.local.json')
    args = parser.parse_args()
    args.state.parent.mkdir(parents=True, exist_ok=True)
    lock = args.state.with_suffix(args.state.suffix + '.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error('A checklist server is already using this results file. Use its URL or stop it first.')
    token = secrets.token_urlsafe(32)

    def state():
        return read_json(args.state) if args.state.exists() else {'schemaVersion': 1, 'revision': 0, 'runs': {}}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # Never log the session URL or notes.

        def reply(self, code, value, content_type='application/json'):
            data = json.dumps(value).encode() if content_type == 'application/json' else value
            self.send_response(code)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
            self.end_headers()
            self.wfile.write(data)

        def authorized(self):
            return hmac.compare_digest(self.headers.get('X-Checklist-Token', ''), token)

        def do_GET(self):
            if self.headers.get('Host') != f'127.0.0.1:{self.server.server_port}':
                return self.reply(403, {'error': 'Invalid host'})
            if self.path == '/':
                return self.reply(200, (DOCS / '3.0-checklist.html').read_bytes(), 'text/html; charset=utf-8')
            if self.path != '/api/state':
                return self.reply(404, {'error': 'Not found'})
            if not self.authorized():
                return self.reply(403, {'error': 'Reopen the URL printed by the launcher.'})
            try:
                self.reply(200, {'catalog': read_json(DOCS / '3.0-cases.json'), 'candidate': read_json(DOCS / '3.0-candidate.json'), 'state': state()})
            except (OSError, ValueError):
                self.reply(500, {'error': 'Cannot read checklist data. Existing results were not replaced.'})

        def do_POST(self):
            origin = f'http://127.0.0.1:{self.server.server_port}'
            if self.path != '/api/result' or not self.authorized() or self.headers.get('Origin') != origin or self.headers.get('Host') != origin.removeprefix('http://'):
                return self.reply(403, {'error': 'Unauthorized save'})
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 32768:
                    raise ValueError('Invalid request size')
                item = json.loads(self.rfile.read(length))
                current = state()
                candidate = read_json(DOCS / '3.0-candidate.json')
                if item.get('revision') != current['revision'] or item.get('candidate') != candidate['id']:
                    return self.reply(409, {'error': 'Results or candidate changed in another session. Reload before saving; your unsaved text remains here.'})
                cases = {case['id']: case for case in read_json(DOCS / '3.0-cases.json')['cases']}
                ids = cases.keys()
                if item.get('id') not in ids or item.get('actor') not in {'user', 'agent'} or item.get('status') not in STATUSES:
                    raise ValueError('Invalid case, actor, or status')
                if cases[item['id']].get('userOnly') and item['actor'] != 'user':
                    raise ValueError('This acceptance case can only be recorded by the user')
                for field in ('notes', 'environment'):
                    if not isinstance(item.get(field), str) or len(item[field]) > 10000:
                        raise ValueError('Notes/environment must be text under 10,000 characters')
                if item['status'] != 'not_run' and (not item['notes'].strip() or not item['environment'].strip()):
                    raise ValueError('Record environment and observed evidence for a test result')
                run = current['runs'].setdefault(candidate['id'], {'candidate': candidate, 'user': {}, 'agent': {}, 'history': []})
                record = {key: item[key] for key in ('status', 'notes', 'environment')}
                record['updatedAt'] = datetime.now(timezone.utc).isoformat()
                previous = run[item['actor']].get(item['id'])
                run['history'].append({'id': item['id'], 'actor': item['actor'], 'previous': previous, 'result': record})
                run[item['actor']][item['id']] = record
                current['revision'] += 1
                atomic_write(args.state, current)
                self.reply(200, {'state': current})
            except (ValueError, KeyError, TypeError) as error:
                self.reply(400, {'error': str(error)})
            except OSError:
                self.reply(500, {'error': 'Save failed. Keep this page open and retry; results were not confirmed saved.'})

    server = HTTPServer(('127.0.0.1', args.port), Handler)
    url = f'http://127.0.0.1:{server.server_port}/#token={token}'
    print(f'Checklist: {url}', flush=True)
    print(f'Results: {args.state.resolve()}\nStop with Control-C. Restart this command to resume.', flush=True)
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
