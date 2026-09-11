<?php
declare(strict_types=1);

function request(string $method = 'GET', ?string $key = null, string $body = ''): array
{
    $headers = "Content-Type: application/json\r\n";
    if ($key !== null) {
        $headers .= "X-Aagedal-Setup-Key: {$key}\r\n";
    }
    $context = stream_context_create(['http' => [
        'method' => $method, 'header' => $headers, 'content' => $body,
        'ignore_errors' => true, 'timeout' => 5,
    ]]);
    $response = @file_get_contents('http://server:8080/index.php', false, $context);
    if ($response === false) {
        throw new RuntimeException('Server not ready');
    }
    preg_match('/\s(\d{3})\s/', $http_response_header[0], $match);
    return [(int) $match[1], json_decode($response, true, 16, JSON_THROW_ON_ERROR), $response];
}

function verify(bool $condition, string $message): void
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
    echo "PASS: {$message}\n";
}

for ($attempt = 0; $attempt < 50; $attempt++) {
    try {
        $discovery = request();
        break;
    } catch (Throwable $error) {
        if ($attempt === 49) {
            throw $error;
        }
        usleep(200000);
    }
}
verify($discovery[0] === 200 && $discovery[1]['service'] === 'aagedal-metadata-sync', 'Public discovery');
verify(count($discovery[1]['checks']) === 2, 'Discovery does not expose database details');
verify(request('DELETE')[0] === 405, 'Unsupported methods rejected');
$action = '{"action":"checkDatabase"}';
$key = str_repeat('a', 64);
verify(request('POST', null, $action)[0] === 401, 'Missing key rejected');
verify(request('POST', str_repeat('b', 64), $action)[0] === 401, 'Wrong key rejected');
verify(request('POST', $key, '{')[0] === 400, 'Malformed JSON rejected');
verify(request('POST', $key, '{"action":"deleteEverything"}')[0] === 400, 'Unknown actions rejected');
verify(request('POST', $key, str_repeat('x', 1025))[0] === 413, 'Oversized requests rejected');

$pdo = new PDO('mysql:host=database;dbname=hosting_test;charset=utf8mb4', 'hosting_test', 'local-test-only', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$pdo->exec("INSERT INTO aftpsync_hosting_probe VALUES ('existing-row', 'leave untouched')");
for ($attempt = 0; $attempt < 3; $attempt++) {
    $result = request('POST', $key, $action);
    verify($result[0] === 200, 'Authenticated database check succeeds');
    verify(count($result[1]['checks']) === 5 && !in_array(false, array_column($result[1]['checks'], 'passed'), true), 'Transactions and Unicode pass');
    verify((int) $pdo->query('SELECT COUNT(*) FROM aftpsync_hosting_probe')->fetchColumn() === 1, 'Probe rolls back without accumulating rows');
}
verify($pdo->query("SELECT payload FROM aftpsync_hosting_probe WHERE probe_id = 'existing-row'")->fetchColumn() === 'leave untouched', 'Existing rows preserved');
$pdo->exec('ALTER TABLE aftpsync_hosting_probe ENGINE=MyISAM');
verify(request('POST', $key, $action)[0] === 503, 'Nontransactional table rejected before writing');
verify((int) $pdo->query('SELECT COUNT(*) FROM aftpsync_hosting_probe')->fetchColumn() === 1, 'Rejected probe leaves table untouched');
$pdo->exec('DROP TABLE aftpsync_hosting_probe');
$failure = request('POST', $key, $action);
verify($failure[0] === 503 && !str_contains($failure[2], 'local-test-only'), 'Missing schema gives a bounded error without credentials');
echo "All hosting integration checks passed.\n";
require __DIR__ . '/live.php';

require __DIR__ . '/templates.php';
