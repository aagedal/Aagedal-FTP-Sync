<?php
declare(strict_types=1);

function api(array $body, string $id, string $key, ?string $setup = null): array {
    $headers = "Content-Type: application/json\r\nX-Aagedal-Protocol: 2\r\nX-Aagedal-Device-ID: $id\r\nX-Aagedal-Device-Key: $key\r\n";
    if ($setup !== null) { $headers .= "X-Aagedal-Setup-Key: $setup\r\n"; }
    $context = stream_context_create(['http' => ['method' => 'POST', 'header' => $headers,
        'content' => json_encode($body, JSON_THROW_ON_ERROR), 'ignore_errors' => true, 'timeout' => 10]]);
    $response = file_get_contents('http://server:8080/index.php', false, $context);
    preg_match('/\s(\d{3})\s/', $http_response_header[0], $match);
    return [(int) $match[1], json_decode($response, true, 32, JSON_THROW_ON_ERROR), $response];
}
function uuid(int $n): string { return sprintf('00000000-0000-4000-8000-%012d', $n); }
$owner = uuid(1); $editor = uuid(2); $reader = uuid(3); $outsider = uuid(4); $limited = uuid(5);
$ownerKey = str_repeat('1', 64); $editorKey = str_repeat('2', 64); $readerKey = str_repeat('3', 64); $limitedKey = str_repeat('5', 64);
$setup = str_repeat('a', 64);
verify(api(['action' => 'listCalendars'], $outsider, str_repeat('4', 64))[0] === 401, 'Unregistered devices cannot list calendars');
verify(api(['action' => 'bootstrap', 'deviceName' => 'Owner'], $owner, $ownerKey, str_repeat('b', 64))[0] === 403, 'Bootstrap needs setup credential');
verify(api(['action' => 'bootstrap', 'deviceName' => 'Owner'], $owner, $ownerKey, $setup)[0] === 200, 'Bootstrap registers first device');
verify(api(['action' => 'bootstrap', 'deviceName' => 'Owner'], $owner, $ownerKey)[0] === 200, 'Bootstrap retry uses saved identity');
verify(api(['action' => 'bootstrap', 'deviceName' => 'Other'], $outsider, str_repeat('4', 64), $setup)[0] === 403, 'Setup key cannot register a second device');
verify(api(['action' => 'listCalendars'], $owner, $editorKey)[0] === 401, 'Device ID cannot impersonate owner without its key');
$pid = uuid(10); $cid = uuid(20); $start = 1800000000000; $end = $start + 86400000;
$profile = ['id' => $pid, 'name' => 'Example ÆØÅ', 'filenamePrefix' => 'EX', 'creator' => 'Example ÆØÅ', 'copyrightNotice' => 'Example'];
$clip = ['id' => uuid(30), 'photographerID' => $pid, 'name' => 'Shared clip', 'startsAt' => $start + 1000, 'endsAt' => $start + 5000,
    'fields' => ['headline' => 'Example headline', 'description' => 'Unicode æøå 📷', 'keywords' => ['example']]];
$hidden = $clip; $hidden['id'] = uuid(31); $hidden['name'] = 'Outside secret'; $hidden['startsAt'] = $end + 1000; $hidden['endsAt'] = $end + 5000;
$crossing = $clip; $crossing['id'] = uuid(32); $crossing['name'] = 'Boundary secret'; $crossing['startsAt'] = $start - 1000; $crossing['endsAt'] = $start + 500;
$doc = ['photographers' => [$profile], 'photographerTracks' => [], 'clips' => [$clip, $hidden, $crossing]];
$create = ['action' => 'createCalendar', 'calendarID' => $cid, 'name' => 'Example calendar', 'timeZone' => 'Europe/Oslo', 'document' => $doc];
$made = api($create, $owner, $ownerKey);
verify($made[0] === 200 && $made[1]['calendar']['revision'] === 1, 'Create validated calendar');
verify(api($create, $owner, $ownerKey)[1]['calendar']['revision'] === 1, 'Calendar creation retry is idempotent');
$doc = $made[1]['calendar']['document'];
function inviteFor(string $role, ?int $start = null, ?int $end = null): string {
    global $cid, $owner, $ownerKey;
    $r = api(['action' => 'createInvite', 'calendarID' => $cid, 'role' => $role, 'rangeStart' => $start, 'rangeEnd' => $end], $owner, $ownerKey);
    verify($r[0] === 200, 'Owner creates invitation');
    return $r[1]['inviteToken'];
}
function joinWith(string $token, string $id, string $key): array {
    return api(['action' => 'acceptInvite', 'inviteToken' => $token, 'deviceName' => 'Example device'], $id, $key);
}
$editorInvite = inviteFor('editor');
verify(joinWith($editorInvite, $editor, $editorKey)[0] === 200, 'Invitation enrolls editor');
verify(joinWith($editorInvite, $editor, $editorKey)[0] === 200, 'Invitation retry is idempotent for same device');
verify(joinWith($editorInvite, $outsider, str_repeat('4', 64))[0] === 403, 'Invitation cannot be reused by another device');
verify(joinWith(inviteFor('reader'), $reader, $readerKey)[0] === 200, 'Read-only invitation enrolls reader');
$rangeInvite = inviteFor('editor', $start, $end);
verify(joinWith($rangeInvite, $limited, $limitedKey)[0] === 200, 'Date-range invitation enrolls limited editor');
$get = ['action' => 'getCalendar', 'calendarID' => $cid];
$limitedGet = api($get, $limited, $limitedKey);
verify($limitedGet[0] === 200 && count($limitedGet[1]['calendar']['document']['clips']) === 1
    && !str_contains($limitedGet[2], 'Outside secret') && !str_contains($limitedGet[2], 'Boundary secret'), 'Date range filters hidden and boundary-crossing metadata on server');
verify(api(['action' => 'createInvite', 'calendarID' => $cid, 'role' => 'editor'], $editor, $editorKey)[0] === 403, 'Editors cannot escalate access through invitations');
$put = ['action' => 'putCalendar', 'calendarID' => $cid, 'expectedRevision' => 1, 'document' => $doc];
verify(api($put, $reader, $readerKey)[0] === 403, 'Reader cannot write');
$edited = $doc; $edited['clips'][0]['fields']['headline'] = 'Owner edit'; $put['document'] = $edited;
verify(api($put, $owner, $ownerKey)[1]['calendar']['revision'] === 2, 'Owner write increments revision');
$stale = api($put, $editor, $editorKey);
verify($stale[0] === 409 && $stale[1]['calendar']['revision'] === 2, 'Concurrent stale write rejected with latest snapshot');
verify(api($get, $editor, $editorKey)[1]['calendar']['document'] === $edited, 'Stale write leaves calendar intact');
$rangeStale = api($put, $limited, $limitedKey);
verify($rangeStale[0] === 409 && !str_contains($rangeStale[2], 'Outside secret'), 'Conflict response respects range permissions');
$rangeDoc = api($get, $limited, $limitedKey)[1]['calendar']['document'];
$rangeDoc['clips'][0]['fields']['description'] = 'Limited editor update';
$rangePut = ['action' => 'putCalendar', 'calendarID' => $cid, 'expectedRevision' => 2, 'document' => $rangeDoc];
verify(api($rangePut, $limited, $limitedKey)[0] === 200, 'Limited editor can update visible clip');
$full = api($get, $owner, $ownerKey)[1]['calendar'];
verify(count($full['document']['clips']) === 3 && $full['document']['clips'][1] === $hidden, 'Range write preserves hidden records');
$badRange = $rangePut; $badRange['expectedRevision'] = 3; $badRange['document']['clips'][0]['endsAt'] = $end + 1;
verify(api($badRange, $limited, $limitedKey)[0] === 403, 'Limited editor cannot move clip beyond range');
$badRange['document'] = $rangeDoc; $badRange['document']['photographers'][0]['creator'] = 'Forbidden change';
verify(api($badRange, $limited, $limitedKey)[0] === 403, 'Limited editor cannot change shared photographer details');
$badRange['document'] = $rangeDoc; $badRange['document']['clips'][0]['id'] = $hidden['id'];
verify(api($badRange, $limited, $limitedKey)[0] === 403, 'Limited editor cannot overwrite a hidden ID');
$invalid = ['action' => 'putCalendar', 'calendarID' => $cid, 'expectedRevision' => 3, 'document' => $full['document']];
$invalid['document']['password'] = 'must never be stored';
verify(api($invalid, $owner, $ownerKey)[0] === 400, 'Unknown private/job fields rejected');
$invalid['document'] = $full['document']; $invalid['document']['photographers'][0]['workHours'] = ['start' => 1];
verify(api($invalid, $owner, $ownerKey)[0] === 400, 'Private work hours cannot enter shared document');
$invalid['document'] = $full['document']; $invalid['document']['clips'][1]['startsAt'] = $start + 2000;
verify(api($invalid, $owner, $ownerKey)[0] === 422, 'Overlapping clips rejected transactionally');
$invalid['document'] = $full['document']; $invalid['document']['clips'][0]['gpsPosition'] = ['latitude' => 100, 'longitude' => 0];
verify(api($invalid, $owner, $ownerKey)[0] === 400, 'Invalid GPS coordinates rejected');
$delete = $rangePut; $delete['expectedRevision'] = 3; $delete['document']['clips'] = [];
verify(api($delete, $limited, $limitedKey)[0] === 200, 'Limited editor can delete a visible clip');
verify(count(api($get, $owner, $ownerKey)[1]['calendar']['document']['clips']) === 2, 'Scoped deletion preserves hidden clips');
verify(api(['action' => 'revokeMember', 'calendarID' => $cid, 'deviceID' => $limited], $owner, $ownerKey)[0] === 200, 'Owner revokes membership');
verify(api($get, $limited, $limitedKey)[0] === 403, 'Revoked device cannot download');
verify(joinWith($rangeInvite, $limited, $limitedKey)[0] === 403, 'Redeemed invitation cannot restore revoked membership');
$pending = inviteFor('editor');
verify(api(['action' => 'revokeInvites', 'calendarID' => $cid], $owner, $ownerKey)[0] === 200, 'Owner revokes invitations');
verify(joinWith($pending, $outsider, str_repeat('4', 64))[0] === 403, 'Revoked invitation cannot enroll a device');
$expired = inviteFor('editor');
$pdo->exec('UPDATE aftpsync_invites SET expires_at = 1');
verify(joinWith($expired, $outsider, str_repeat('4', 64))[0] === 403, 'Expired invitation cannot enroll a device');
verify(!str_contains(api($get, $owner, $ownerKey)[2], $ownerKey), 'API does not echo device credentials');
echo "All live sync integration checks passed.\n";

// Exercise early endpoint failures before live.php or database access is possible.
$installation = sys_get_temp_dir() . '/metadata-install-' . bin2hex(random_bytes(8));
mkdir($installation . '/public', 0700, true);
copy('/srv/public/index.php', $installation . '/public/index.php');
function installationProbe(string $installation): array {
    $script = '$_SERVER["REQUEST_METHOD"] = "POST"; $_SERVER["HTTP_X_AAGEDAL_PROTOCOL"] = "2"; require '
        . var_export($installation . '/public/index.php', true) . ';';
    $output = []; $status = 0;
    exec(escapeshellarg(PHP_BINARY) . ' -r ' . escapeshellarg($script), $output, $status);
    if ($status !== 0) { throw new RuntimeException('Installation probe failed'); }
    return json_decode(implode("\n", $output), true, 16, JSON_THROW_ON_ERROR);
}
try {
    $missingConfig = installationProbe($installation);
    verify($missingConfig['protocolVersion'] === 2 && $missingConfig['error'] === 'not_configured', 'Missing private config uses requested calendar protocol');
    copy('/srv/tests/config.php', $installation . '/config.php');
    $missingAPI = installationProbe($installation);
    verify($missingAPI['protocolVersion'] === 2 && $missingAPI['error'] === 'live_api_missing', 'Missing live.php returns specific installation error');
} finally {
    @unlink($installation . '/config.php');
    unlink($installation . '/public/index.php');
    rmdir($installation . '/public');
    rmdir($installation);
}
