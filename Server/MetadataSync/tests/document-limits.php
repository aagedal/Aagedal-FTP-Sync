<?php
declare(strict_types=1);

// Test actual wire requests at the stored-document ceiling, in both namespaces.
function limitAPI(array $body, int $protocol): array {
    global $owner, $ownerKey;
    if ($protocol === 3) { $body['capabilities'] = ['metadata-templates-v1']; }
    $headers = "Content-Type: application/json\r\nX-Aagedal-Protocol: $protocol\r\nX-Aagedal-Device-ID: $owner\r\nX-Aagedal-Device-Key: $ownerKey\r\n";
    $context = stream_context_create(['http' => ['method' => 'POST', 'header' => $headers,
        'content' => json_encode($body, JSON_THROW_ON_ERROR | JSON_UNESCAPED_UNICODE),
        'ignore_errors' => true, 'timeout' => 10]]);
    $response = file_get_contents('http://server:8080/index.php', false, $context);
    preg_match('/\s(\d{3})\s/', $http_response_header[0], $match);
    return [(int) $match[1], json_decode($response, true, 32, JSON_THROW_ON_ERROR)];
}
foreach ([2, 3] as $protocol) {
    foreach (['x', 'æ'] as $character) {
        $profile = ['id' => uuid(8000), 'name' => 'Limit', 'filenamePrefix' => 'L', 'creator' => '', 'copyrightNotice' => ''];
        $clips = [];
        for ($i = 0; $i < 62; $i++) {
            $clips[] = ['id' => uuid(8100 + $i), 'photographerID' => $profile['id'], 'name' => 'Limit',
                'startsAt' => 1800000000000 + $i * 10000, 'endsAt' => 1800000005000 + $i * 10000,
                'fields' => ['headline' => '', 'description' => str_repeat($character, intdiv(16000, strlen($character))), 'keywords' => []]];
        }
        $document = ['photographers' => [$profile], 'photographerTracks' => [], 'clips' => $clips];
        $excess = strlen(json_encode($document, JSON_UNESCAPED_UNICODE)) - 1000000;
        $last = &$document['clips'][61]['fields']['description'];
        $last = str_repeat('x', strlen($last) - $excess);
        unset($last);
        verify(strlen(json_encode($document, JSON_UNESCAPED_UNICODE)) === 1000000, 'Fixture reaches exact document byte limit');
        $id = uuid(9000 + $protocol * 10 + ($character === 'x' ? 0 : 1));
        $create = ['action' => 'createCalendar', 'calendarID' => $id, 'name' => 'Limit', 'timeZone' => 'Europe/Oslo', 'document' => $document];
        if ($protocol === 3) { $create['documentSchemaVersion'] = 3; }
        verify(limitAPI($create, $protocol)[0] === 200, "P$protocol $character create accepts exact document limit");
        $put = $create; $put['action'] = 'putCalendar'; $put['expectedRevision'] = 1;
        verify(limitAPI($put, $protocol)[0] === 200, "P$protocol $character update accepts same document limit");
        $put['expectedRevision'] = 2;
        $put['document']['clips'][61]['fields']['description'] .= 'x';
        $failed = limitAPI($put, $protocol);
        verify($failed[0] === 413 && $failed[1]['error'] === 'calendar_too_large', 'Update rejects one byte over limit');
        $after = limitAPI(['action' => 'getCalendar', 'calendarID' => $id], $protocol);
        verify($after[1]['calendar']['revision'] === 2 && $after[1]['calendar']['document'] === $document, 'Rejected update preserves revision and document');
        $create['calendarID'] = uuid(9500 + $protocol * 10 + ($character === 'x' ? 0 : 1));
        $create['document'] = $put['document'];
        $failed = limitAPI($create, $protocol);
        verify($failed[0] === 413 && $failed[1]['error'] === 'calendar_too_large', 'Create rejects one byte over limit');
        verify(limitAPI(['action' => 'getCalendar', 'calendarID' => $create['calendarID']], $protocol)[0] === 403, 'Rejected create leaves no calendar');
    }
}
echo "All document size integration checks passed.\n";
