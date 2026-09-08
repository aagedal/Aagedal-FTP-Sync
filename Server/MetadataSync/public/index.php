<?php
declare(strict_types=1);

// This endpoint is a hosting preflight, not a calendar sync implementation.
// PHP errors must never expose database credentials or server paths to clients.
ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

function respond(int $status, array $checks = [], ?string $error = null): never
{
    http_response_code($status);
    $body = [
        'service' => 'aagedal-metadata-sync',
        'protocolVersion' => 1,
        'stage' => 'hosting-check',
        'checks' => $checks,
    ];
    if ($error !== null) {
        $body['error'] = $error;
    }
    echo json_encode($body, JSON_THROW_ON_ERROR | JSON_UNESCAPED_UNICODE);
    exit;
}

$checks = [
    ['name' => 'PHP runtime', 'passed' => PHP_VERSION_ID >= 80200],
    ['name' => 'MySQL driver', 'passed' => extension_loaded('pdo_mysql')],
];
$method = $_SERVER['REQUEST_METHOD'] ?? '';
if ($method === 'GET') {
    // Public discovery does not connect to the database or load credentials.
    respond(200, $checks);
}
if ($method !== 'POST') {
    header('Allow: GET, POST');
    respond(405, [], 'method_not_allowed');
}

$pdo = null;
try {
    if (PHP_VERSION_ID < 80200 || !extension_loaded('pdo_mysql')) {
        respond(503, [], 'runtime_unavailable');
    }
    // Point this at a private file if the host uses a different directory layout.
    $configPath = dirname(__DIR__) . '/config.php';
    if (!is_file($configPath)) {
        respond(503, [], 'not_configured');
    }
    $config = require $configPath;
    if (!is_array($config) || ($config['hosting_checks_enabled'] ?? false) !== true) {
        respond(404, [], 'hosting_check_disabled');
    }
    $expectedHash = $config['setup_key_sha256'] ?? '';
    $key = $_SERVER['HTTP_X_AAGEDAL_SETUP_KEY'] ?? '';
    if (!is_string($expectedHash) || !preg_match('/\A[a-f0-9]{64}\z/', $expectedHash)) {
        respond(503, [], 'not_configured');
    }
    if (!preg_match('/\A[a-f0-9]{64}\z/', $key)
        || !hash_equals($expectedHash, hash('sha256', $key))) {
        respond(401, [], 'unauthorized');
    }
    if ((int) ($_SERVER['CONTENT_LENGTH'] ?? 0) > 1024) {
        respond(413, [], 'request_too_large');
    }
    $stream = fopen('php://input', 'rb');
    $body = $stream === false ? false : stream_get_contents($stream, 1025);
    if (is_resource($stream)) {
        fclose($stream);
    }
    if ($body === false || strlen($body) > 1024) {
        respond(413, [], 'request_too_large');
    }
    try {
        $request = json_decode($body, true, 8, JSON_THROW_ON_ERROR);
    } catch (JsonException $error) {
        respond(400, [], 'invalid_request');
    }
    if (!is_array($request) || ($request['action'] ?? '') !== 'checkDatabase') {
        respond(400, [], 'invalid_request');
    }

    $host = $config['database_host'] ?? '';
    $database = $config['database_name'] ?? '';
    $port = filter_var($config['database_port'] ?? 3306, FILTER_VALIDATE_INT);
    foreach ([$host, $database] as $value) {
        if (!is_string($value) || $value === '' || preg_match('/[;\x00-\x20]/', $value)) {
            respond(503, [], 'invalid_configuration');
        }
    }
    if ($port === false || $port < 1 || $port > 65535) {
        respond(503, [], 'invalid_configuration');
    }
    $pdo = new PDO(
        "mysql:host={$host};port={$port};dbname={$database};charset=utf8mb4",
        $config['database_user'] ?? '',
        $config['database_password'] ?? '',
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
         PDO::ATTR_EMULATE_PREPARES => false,
         PDO::ATTR_TIMEOUT => 5]
    );
    $pdo->exec('SET SESSION innodb_lock_wait_timeout = 5');
    $engine = $pdo->query(
        "SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'aftpsync_hosting_probe'"
    )->fetchColumn();
    // Check before writing: a nontransactional table could retain test data.
    if (strtolower((string) $engine) !== 'innodb') {
        respond(503, [], 'probe_table_unavailable');
    }
    $probeID = bin2hex(random_bytes(16));
    $payload = 'Metadata prøve: æøå — 📷';
    $pdo->beginTransaction();
    $insert = $pdo->prepare('INSERT INTO aftpsync_hosting_probe (probe_id, payload) VALUES (?, ?)');
    $insert->execute([$probeID, 'initial']);
    $update = $pdo->prepare('UPDATE aftpsync_hosting_probe SET payload = ? WHERE probe_id = ?');
    $update->execute([$payload, $probeID]);
    $select = $pdo->prepare('SELECT payload FROM aftpsync_hosting_probe WHERE probe_id = ?');
    $select->execute([$probeID]);
    $unicodeOK = $select->fetchColumn() === $payload;
    $select->closeCursor();
    $pdo->rollBack();
    $select->execute([$probeID]);
    $rollbackOK = $select->fetchColumn() === false;
    $checks[] = ['name' => 'Database read/write', 'passed' => true];
    $checks[] = ['name' => 'Transaction rollback', 'passed' => $rollbackOK];
    $checks[] = ['name' => 'Unicode metadata', 'passed' => $unicodeOK];
    respond($unicodeOK && $rollbackOK ? 200 : 503, $checks);
} catch (Throwable $error) {
    if ($pdo instanceof PDO && $pdo->inTransaction()) {
        $pdo->rollBack();
    }
    // Deliberately omit exception messages: PDO errors may contain private details.
    error_log('Aagedal metadata sync: hosting check failed. Verify private configuration and probe table.');
    respond(503, [], 'hosting_check_failed');
}
