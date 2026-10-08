#!/usr/bin/env python3
"""Back up, restore, or apply bundled additive schemas to the Compose database."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def database_command(action):
    if action == 'backup':
        command = 'export MYSQL_PWD="$(cat /run/secrets/db_password)"; exec mariadb-dump -u sync --single-transaction --skip-lock-tables --hex-blob sync'
    else:
        command = 'export MYSQL_PWD="$(cat /run/secrets/db_root_password)"; exec mariadb -u root sync'
    return ['docker', 'compose', '-f', str(ROOT / 'compose.yaml'), 'exec', '-T', 'database', 'sh', '-ec', command]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    backup = commands.add_parser('backup', help='Write a transaction-consistent SQL dump; refuses to overwrite')
    backup.add_argument('file', type=Path)
    restore = commands.add_parser('restore', help='Replace table contents from a trusted backup; stop the app first')
    restore.add_argument('file', type=Path)
    restore.add_argument('--replace', action='store_true', required=True)
    commands.add_parser('migrate', help='Apply the three bundled additive SQL files; back up and stop the app first')
    args = parser.parse_args()
    os.umask(0o077)
    if args.action == 'backup':
        target = args.file.resolve()
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            parser.error('Backup already exists; choose a new filename.')
        descriptor, temporary = tempfile.mkstemp(prefix='.sync-backup-', dir=target.parent)
        try:
            with os.fdopen(descriptor, 'wb') as output:
                subprocess.run(database_command('backup'), cwd=ROOT, stdout=output, check=True)
                output.flush()
                os.fsync(output.fileno())
            os.link(temporary, target)  # Publish only a complete dump; never replace an existing file.
        finally:
            os.unlink(temporary)
        print(f'Backup saved: {target}')
    elif args.action == 'restore':
        with args.file.resolve().open('rb') as source:
            subprocess.run(database_command('restore'), cwd=ROOT, stdin=source, check=True)
        print('Restore completed. Verify database and client revision consistency before resuming sync.')
    else:
        for name in ('schema.sql', 'schema-live-sync.sql', 'schema-template-sync.sql'):
            with (ROOT / name).open('rb') as source:
                subprocess.run(database_command('migrate'), cwd=ROOT, stdin=source, check=True)
        print('Bundled additive schemas applied. Existing calendar namespaces were not merged.')


if __name__ == '__main__':
    main()
