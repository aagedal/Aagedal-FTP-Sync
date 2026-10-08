<?php
declare(strict_types=1);

try {
    $config = require '/var/www/config.php';
    $pdo = new PDO(
        "mysql:host={$config['database_host']};port={$config['database_port']};dbname={$config['database_name']};charset=utf8mb4",
        $config['database_user'], $config['database_password'],
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 3]
    );
    $tables = ['aftpsync_hosting_probe', 'aftpsync_devices', 'aftpsync_bootstrap',
        'aftpsync_calendars', 'aftpsync_members', 'aftpsync_invites',
        'aftpsync_v3_calendars', 'aftpsync_v3_members', 'aftpsync_v3_invites'];
    $query = $pdo->prepare('SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?');
    foreach ($tables as $table) {
        $query->execute([$table]);
        if (strtolower((string) $query->fetchColumn()) !== 'innodb') { throw new RuntimeException(); }
    }
    if ((int) $pdo->query('SELECT COUNT(*) FROM aftpsync_bootstrap WHERE id = 1')->fetchColumn() !== 1) {
        throw new RuntimeException();
    }
    $context = stream_context_create(['http' => ['timeout' => 3]]);
    $response = json_decode((string) @file_get_contents('http://127.0.0.1/index.php', false, $context), true, 16, JSON_THROW_ON_ERROR);
    if (($response['service'] ?? '') !== 'aagedal-metadata-sync'
        || in_array(false, array_column($response['checks'] ?? [], 'passed'), true)) {
        throw new RuntimeException();
    }
    echo "Sync HTTP and database ready.\n";
} catch (Throwable $error) {
    fwrite(STDERR, "Sync not ready. Check database connectivity and installed InnoDB schemas.\n");
    exit(1);
}
