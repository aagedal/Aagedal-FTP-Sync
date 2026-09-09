#!/usr/bin/env python3
"""Create private hosting configuration locally, without command-line secrets."""
import getpass
import hashlib
import os
from pathlib import Path
import secrets


def php_string(value):
    if '\x00' in value or '\n' in value or '\r' in value:
        raise ValueError('Configuration values must be single-line text.')
    return "'" + value.replace('\\', '\\\\').replace("'", "\\'") + "'"


def main():
    folder = Path(__file__).resolve().parent
    config_path = folder / 'config.php'
    key_path = folder / 'hosting-check-key.txt'
    if config_path.exists() or key_path.exists():
        raise SystemExit('Existing configuration/key found. Move it aside before generating a new pair.')
    host = input('MySQL host from your hosting provider: ').strip()
    port = int(input('MySQL port [3306]: ').strip() or '3306')
    database = input('Database name: ').strip()
    user = input('Database user: ').strip()
    password = getpass.getpass('Database password (hidden): ')
    if not host or not database or not user or not 1 <= port <= 65535:
        raise SystemExit('Host, database, user and a valid port are required.')
    key = secrets.token_hex(32)
    config = "<?php\nreturn [\n" + '\n'.join([
        f"    'database_host' => {php_string(host)},",
        f"    'database_port' => {port},",
        f"    'database_name' => {php_string(database)},",
        f"    'database_user' => {php_string(user)},",
        f"    'database_password' => {php_string(password)},",
        f"    'setup_key_sha256' => '{hashlib.sha256(key.encode()).hexdigest()}',",
        "    'hosting_checks_enabled' => true,",
        "    'bootstrap_enabled' => false,",
    ]) + '\n];\n'
    for path, contents in [(config_path, config), (key_path, key + '\n')]:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as output:
            output.write(contents)
    print(f'Private configuration: {config_path}')
    print(f'Hosting check key: {key_path}')
    print('Upload config.php outside the public web directory. Keep the key file on this Mac.')


if __name__ == '__main__':
    main()
