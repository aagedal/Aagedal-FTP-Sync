<?php
declare(strict_types=1);

// Both requests are sent before either response is read. Holding the common DB
// row lets us prove both different owners reached the creation critical section.
// SHOW FULL PROCESSLIST exposes this database user's own sessions without PROCESS.
function beginRaceRequest(array $body, int $protocol, string $device, string $key) {
    if ($protocol === 3) { $body['capabilities'] = ['metadata-templates-v1']; }
    $json = json_encode($body, JSON_THROW_ON_ERROR);
    $socket = stream_socket_client('tcp://server:8080', $errno, $error, 5);
    if ($socket === false) { throw new RuntimeException('Cannot connect to disposable race server'); }
    stream_set_timeout($socket, 10);
    $wire = "POST /index.php HTTP/1.1\r\nHost: server:8080\r\nConnection: close\r\nContent-Type: application/json\r\n"
        . "X-Aagedal-Protocol: $protocol\r\nX-Aagedal-Device-ID: $device\r\nX-Aagedal-Device-Key: $key\r\n"
        . 'Content-Length: ' . strlen($json) . "\r\n\r\n" . $json;
    for ($sent = 0, $length = strlen($wire); $sent < $length;) {
        $count = fwrite($socket, substr($wire, $sent));
        if ($count === false || $count === 0) { fclose($socket); throw new RuntimeException('Race request write failed'); }
        $sent += $count;
    }
    return $socket;
}
function finishRaceRequest($socket): array {
    $wire = stream_get_contents($socket, 2097152);
    $metadata = stream_get_meta_data($socket);
    fclose($socket);
    if ($wire === false || $metadata['timed_out']) { throw new RuntimeException('Race response timed out'); }
    $parts = explode("\r\n\r\n", $wire, 2);
    if (count($parts) !== 2 || !preg_match('/\AHTTP\/1\.[01] (\d{3}) /', $parts[0], $match)) {
        throw new RuntimeException('Invalid race response');
    }
    return [(int) $match[1], json_decode($parts[1], true, 32, JSON_THROW_ON_ERROR)];
}
for ($iteration = 0; $iteration < 8; $iteration++) {
    $raceID = uuid(800 + $iteration);
    $legacyRequest = ['action' => 'createCalendar', 'calendarID' => $raceID,
        'name' => 'Race legacy ' . $iteration, 'timeZone' => 'Europe/Oslo', 'document' => $doc];
    $templateRequest = $make3;
    $templateRequest['calendarID'] = $raceID;
    $templateRequest['name'] = 'Race template ' . $iteration;
    $sockets = [];
    $pdo->beginTransaction();
    try {
        $pdo->query('SELECT device_id FROM aftpsync_bootstrap WHERE id = 1 FOR UPDATE')->fetchColumn();
        // Alternate arrival order; owners are deliberately distinct so the old
        // per-device lock cannot serialize this fixture by accident.
        foreach ($iteration % 2 === 0 ? [2, 3] : [3, 2] as $protocol) {
            $sockets[$protocol] = $protocol === 2
                ? beginRaceRequest($legacyRequest, 2, $owner, $ownerKey)
                : beginRaceRequest($templateRequest, 3, $editor, $editorKey);
        }
        $deadline = microtime(true) + 2.0;
        $waiting = 0;
        do {
            $processes = $pdo->query('SHOW FULL PROCESSLIST')->fetchAll(PDO::FETCH_ASSOC);
            $waiting = count(array_filter($processes, fn($process) =>
                ($process['Info'] ?? '') === 'SELECT device_id FROM aftpsync_bootstrap WHERE id = 1 FOR UPDATE'));
            if ($waiting >= 2) { break; }
            usleep(10000);
        } while (microtime(true) < $deadline);
        verify($waiting >= 2, 'Two different owners concurrently reach namespace creation lock');
        $pdo->commit();
        $results = [];
        foreach ($sockets as $protocol => $socket) { $results[$protocol] = finishRaceRequest($socket); }
        $sockets = [];
        $statuses = [$results[2][0], $results[3][0]];
        sort($statuses);
        verify($statuses === [200, 409], 'Exactly one namespace wins concurrent UUID creation');
        $winner = $results[2][0] === 200 ? 2 : 3;
        $loser = $winner === 2 ? 3 : 2;
        verify(($results[$loser][1]['error'] ?? '') === 'id_in_use'
            && !isset($results[$loser][1]['calendar']), 'Losing create returns no calendar payload');
        $expected = $winner === 2 ? $legacyRequest : $templateRequest;
        $counts = [];
        foreach ([2 => 'aftpsync_calendars', 3 => 'aftpsync_v3_calendars'] as $protocol => $table) {
            $query = $pdo->prepare('SELECT * FROM ' . $table . ' WHERE id = ?');
            $query->execute([$raceID]);
            $rows = $query->fetchAll(PDO::FETCH_ASSOC);
            $counts[$protocol] = count($rows);
            if ($protocol === $winner) {
                verify(count($rows) === 1 && (int) $rows[0]['revision'] === 1
                    && $rows[0]['name'] === $expected['name']
                    && json_decode($rows[0]['document'], true, 32, JSON_THROW_ON_ERROR) === $expected['document'],
                    'Winning namespace preserves exact document and initial revision');
            }
        }
        verify($counts[$winner] === 1 && $counts[$loser] === 0, 'Concurrent creation never produces a cross-table collision');
    } finally {
        if ($pdo->inTransaction()) { $pdo->rollBack(); }
        foreach ($sockets as $socket) { if (is_resource($socket)) { fclose($socket); } }
    }
}
echo "All concurrent namespace creation checks passed.\n";
