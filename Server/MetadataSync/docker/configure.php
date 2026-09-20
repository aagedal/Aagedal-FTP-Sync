<?php
declare(strict_types=1);

// Run as root before Apache starts. Bind-mounted secrets may be owner-only;
// workers receive only the private generated config, never the raw setup key.
try {
    function secret(string $variable, string $default): string {
        $path = getenv($variable) ?: $default;
        $value = @file_get_contents($path);
        if ($value === false) { throw new RuntimeException('Missing secret'); }
        $value = rtrim($value, "\r\n");
        if ($value === '' || str_contains($value, "\0")) { throw new RuntimeException('Invalid secret'); }
        return $value;
    }
    $setupKey = secret('SYNC_SETUP_KEY_FILE', '/run/secrets/setup_key');
    if (!preg_match('/\A[a-f0-9]{64}\z/', $setupKey)) { throw new RuntimeException('Invalid setup key'); }
    $enabled = getenv('SYNC_SETUP_ENABLED') ?: 'false';
    if (!in_array($enabled, ['true', 'false'], true)) { throw new RuntimeException('Invalid setup flag'); }
    $port = filter_var(getenv('SYNC_DB_PORT') ?: '3306', FILTER_VALIDATE_INT);
    if (!$port || $port < 1 || $port > 65535) { throw new RuntimeException('Invalid port'); }
    $host = getenv('SYNC_DB_HOST') ?: 'database';
    $database = getenv('SYNC_DB_NAME') ?: 'sync';
    foreach ([$host, $database] as $value) {
        if (preg_match('/[;\x00-\x20]/', $value)) { throw new RuntimeException('Invalid database setting'); }
    }
    $config = [
        'database_host' => $host,
        'database_port' => $port,
        'database_name' => $database,
        'database_user' => getenv('SYNC_DB_USER') ?: 'sync',
        'database_password' => secret('SYNC_DB_PASSWORD_FILE', '/run/secrets/db_password'),
        'setup_key_sha256' => hash('sha256', $setupKey),
        'hosting_checks_enabled' => $enabled === 'true',
        'bootstrap_enabled' => $enabled === 'true',
    ];
    $temporary = '/var/www/config.php.new';
    if (file_put_contents($temporary, "<?php\nreturn " . var_export($config, true) . ";\n") === false
        || !chmod($temporary, 0600) || !rename($temporary, '/var/www/config.php')) {
        throw new RuntimeException('Cannot write configuration');
    }
} catch (Throwable $error) {
    // Do not expose secrets or exception details in container logs.
    fwrite(STDERR, "Sync configuration failed. Check secret files and SYNC_* settings.\n");
    exit(1);
}
