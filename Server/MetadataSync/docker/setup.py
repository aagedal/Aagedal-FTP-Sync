#!/usr/bin/env python3
"""Generate Compose secrets locally. Never print credentials or overwrite an installation."""
import argparse
import os
from pathlib import Path
import re
import secrets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--domain', help='Public DNS name, for example sync.example.com')
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    domain = args.domain or input('Public sync DNS name (no https:// or path): ').strip()
    if len(domain) > 253 or '.' not in domain or not all(
        re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?', label)
        for label in domain.split('.')
    ):
        parser.error('Enter a DNS name such as sync.example.com.')
    folder = args.output.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    if (folder / '.env').exists() or (folder / 'secrets').exists():
        parser.error('Existing .env or secrets directory found; preserve it instead of rerunning setup.')
    os.umask(0o077)
    (folder / 'secrets').mkdir(mode=0o700)
    for name in ('db_password', 'db_root_password', 'setup_key'):
        with (folder / 'secrets' / name).open('x') as output:
            output.write(secrets.token_hex(32) + '\n')
    with (folder / '.env').open('x') as output:
        output.write(f'SYNC_DOMAIN={domain.lower()}\nSYNC_SETUP_ENABLED=true\nSYNC_HTTP_PORT=8080\n')
    print(f'Created {folder / ".env"} and three private secret files.')
    print('Keep these files. Do not regenerate them when upgrading or restoring.')
    print('After connecting the first Mac, set SYNC_SETUP_ENABLED=false in .env and recreate the app container.')


if __name__ == '__main__':
    main()
