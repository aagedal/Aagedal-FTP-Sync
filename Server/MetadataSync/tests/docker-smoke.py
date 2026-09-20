#!/usr/bin/env python3
"""Exercise the production Compose image with disposable credentials and volumes."""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    project = 'aftpsync-image-test-' + uuid.uuid4().hex[:10]
    with tempfile.TemporaryDirectory(prefix='aftpsync-image-test-') as temporary:
        folder = Path(temporary)
        subprocess.run([sys.executable, str(ROOT / 'docker/setup.py'), '--domain', 'sync.example.invalid',
                        '--output', str(folder)], check=True)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        env = dict(os.environ, COMPOSE_PROJECT_NAME=project, SYNC_SECRETS_DIR=str(folder / 'secrets'),
                   SYNC_HTTP_PORT=str(port), SYNC_SETUP_ENABLED='true')
        compose = ['docker', 'compose', '--env-file', str(folder / '.env'), '-p', project,
                   '-f', str(ROOT / 'compose.yaml')]

        def run(*args, **kwargs):
            return subprocess.run([*compose, *args], cwd=ROOT, env=env, check=True, **kwargs)

        device_id, device_key = str(uuid.uuid4()), secrets.token_hex(32)
        setup_key = (folder / 'secrets/setup_key').read_text().strip()
        endpoint = f'http://127.0.0.1:{port}/index.php'

        def request(body=None, protocol=3, setup=False, device=device_id, key=device_key, path='/index.php'):
            headers = {'Content-Type': 'application/json', 'X-Aagedal-Device-ID': device,
                       'X-Aagedal-Device-Key': key}
            if protocol:
                headers['X-Aagedal-Protocol'] = str(protocol)
            if setup:
                headers['X-Aagedal-Setup-Key'] = setup_key
            if body is not None and protocol == 3:
                body = dict(body, capabilities=['metadata-templates-v1'])
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(endpoint.replace('/index.php', path), data=data, headers=headers)
            try:
                response = urllib.request.urlopen(req, timeout=10)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                raw = response.read()
                content = json.loads(raw) if 'application/json' in response.headers.get('Content-Type', '') else raw
                return response.status, content

        try:
            run('up', '-d', '--build', '--wait')
            assert request()[0] == 200
            for path in ['/config.php', '/secrets/setup_key', '/schema.sql', '/tests/run.php', '/docker/configure.php']:
                assert request(path=path)[0] == 404, path
            print('PASS: HTTP discovery and private files excluded from document root', flush=True)
            assert request({'action': 'checkDatabase'}, protocol=None, setup=True)[0] == 200
            assert request({'action': 'bootstrap', 'deviceName': 'Disposable owner'}, setup=True)[0] == 200
            assert request({'action': 'getCapabilities'})[0] == 200
            calendar_id, photographer_id = str(uuid.uuid4()), str(uuid.uuid4())
            document = {'photographers': [{'id': photographer_id, 'name': 'Test ÆØÅ', 'filenamePrefix': 'T',
                'creator': 'Test', 'copyrightNotice': '© {photographer}', 'copyrightTemplateVersion': 1}],
                'photographerTracks': [], 'clips': []}
            status, created = request({'action': 'createCalendar', 'calendarID': calendar_id,
                'name': 'Docker smoke', 'timeZone': 'Europe/Oslo', 'documentSchemaVersion': 3, 'document': document})
            assert status == 200, created
            document = created['calendar']['document']
            print('PASS: database checks, bootstrap and protocol-3 publication through Apache', flush=True)
            status, invite = request({'action': 'createInvite', 'calendarID': calendar_id, 'role': 'reader'})
            assert status == 200
            reader_id, reader_key = str(uuid.uuid4()), secrets.token_hex(32)
            assert request({'action': 'acceptInvite', 'inviteToken': invite['inviteToken'], 'deviceName': 'Reader'},
                           device=reader_id, key=reader_key)[0] == 200
            assert request({'action': 'getCalendar', 'calendarID': calendar_id}, device=reader_id, key=reader_key)[0] == 200
            print('PASS: invitation and second-device receipt', flush=True)
            # Recreate all containers, retaining the named database volume.
            run('down')
            run('up', '-d', '--wait')
            assert request({'action': 'getCalendar', 'calendarID': calendar_id})[1]['calendar']['document'] == document
            print('PASS: calendars and credentials survive container recreation', flush=True)
            backup = folder / 'backup.sql'
            helper = [sys.executable, str(ROOT / 'docker/database.py')]
            subprocess.run([*helper, 'backup', str(backup)], env=env, check=True)
            assert backup.stat().st_size > 0 and backup.stat().st_mode & 0o077 == 0
            updated = json.loads(json.dumps(document))
            updated['photographers'][0]['name'] = 'Changed after backup'
            assert request({'action': 'putCalendar', 'calendarID': calendar_id, 'expectedRevision': 1,
                            'documentSchemaVersion': 3, 'document': updated})[0] == 200
            run('stop', 'app')
            subprocess.run([*helper, 'restore', str(backup), '--replace'], env=env, check=True)
            subprocess.run([*helper, 'migrate'], env=env, check=True)
            env['SYNC_SETUP_ENABLED'] = 'false'
            run('up', '-d', '--wait')
            assert request({'action': 'getCalendar', 'calendarID': calendar_id})[1]['calendar']['document'] == document
            assert request({'action': 'checkDatabase'}, protocol=None, setup=True)[0] == 404
            assert request({'action': 'bootstrap', 'deviceName': 'Another owner'}, setup=True,
                           device=str(uuid.uuid4()), key=secrets.token_hex(32))[0] == 403
            assert request({'action': 'getCapabilities'})[0] == 200
            print('PASS: backup/restore, additive migration and setup closure preserve normal sync', flush=True)
            # Validate the optional proxy config without requesting a public certificate.
            subprocess.run(['docker', 'run', '--rm', '-e', 'SYNC_DOMAIN=sync.example.invalid',
                '-v', str(ROOT / 'docker/Caddyfile') + ':/etc/caddy/Caddyfile:ro', 'caddy:2',
                'caddy', 'validate', '--config', '/etc/caddy/Caddyfile'], check=True)
            print('PASS: Caddy configuration validates (public certificate issuance not exercised)', flush=True)
        finally:
            run('down', '-v')  # Only this script's unique disposable project.


if __name__ == '__main__':
    main()
