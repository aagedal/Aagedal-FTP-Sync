<?php
declare(strict_types=1);

// Disposable database only; runs after the unchanged protocol-two suite.
function api3(array $body, string $id, string $key, bool $capable = true): array {
    if ($capable) { $body['capabilities'] = ['metadata-templates-v1']; }
    $headers = "Content-Type: application/json\r\nX-Aagedal-Protocol: 3\r\nX-Aagedal-Device-ID: $id\r\nX-Aagedal-Device-Key: $key\r\n";
    $context = stream_context_create(['http' => ['method' => 'POST', 'header' => $headers,
        'content' => json_encode($body, JSON_THROW_ON_ERROR), 'ignore_errors' => true, 'timeout' => 10]]);
    $response = file_get_contents('http://server:8080/index.php', false, $context);
    preg_match('/\s(\d{3})\s/', $http_response_header[0], $match);
    return [(int) $match[1], json_decode($response, true, 32, JSON_THROW_ON_ERROR), $response];
}
function noTemplatePayload(array $response): bool {
    return !isset($response[1]['calendar']) && !str_contains($response[2], 'TEMPLATE_PRIVATE_SOURCE');
}
$caps = api3(['action' => 'getCapabilities'], $owner, $ownerKey);
verify($caps[0] === 200 && $caps[1]['protocolVersion'] === 3
    && $caps[1]['capabilities'] === ['metadata-templates-v1']
    && $caps[1]['documentSchemaVersions'] === [1, 3]
    && $caps[1]['templateLanguageVersions'] === [1] && noTemplatePayload($caps), 'Authenticated document-free capabilities');
verify(api3(['action' => 'getCapabilities'], uuid(700), str_repeat('7', 64))[0] === 401, 'Capabilities require registered identity');
$v3id = uuid(301);
$v3doc = $doc;
$v3doc['photographers'][0]['copyrightNotice'] = 'TEMPLATE_PRIVATE_SOURCE © {date:YYYY-MM-DD} {photographer}';
$v3doc['photographers'][0]['copyrightTemplateVersion'] = 1;
$v3doc['clips'][0]['fields']['description'] = 'TEMPLATE_PRIVATE_SOURCE {gps:city} {{literal}}';
$v3doc['clips'][0]['fields']['keywords'] = ['one,two', ' {persons} '];
$v3doc['clips'][0]['fields']['templateVersions'] = ['description' => 1, 'keywords' => 1];
$make3 = ['action' => 'createCalendar', 'calendarID' => $v3id, 'name' => 'Private v3 calendar',
    'timeZone' => 'Europe/Oslo', 'documentSchemaVersion' => 3, 'document' => $v3doc];
$made3 = api3($make3, $owner, $ownerKey);
verify($made3[0] === 200 && $made3[1]['calendar']['document'] === $v3doc
    && $made3[1]['calendar']['documentSchemaVersion'] === 3, 'V3 retains exact sources and markers');
verify(api3($make3, $owner, $ownerKey)[1]['calendar']['revision'] === 1, 'V3 create retry is idempotent');
verify((int) $pdo->query("SELECT COUNT(*) FROM aftpsync_calendars WHERE id = '$v3id'")->fetchColumn() === 0, 'V3 never enters legacy table');
$list2 = api(['action' => 'listCalendars'], $owner, $ownerKey);
verify(!str_contains($list2[2], $v3id) && !str_contains($list2[2], 'Private v3'), 'Legacy list omits v3 identity and name');
verify(api3(['action' => 'getCalendar', 'calendarID' => $v3id], $editor, $editorKey, false)[0] === 403, 'Unauthorized missing-capability lookup stays generic');
$list3 = api3(['action' => 'listCalendars'], $owner, $ownerKey);
verify(count($list3[1]['calendars']) === 1 && $list3[1]['calendars'][0]['minimumClientProtocol'] === 3, 'V3 list is namespace-specific');
foreach (['getCalendar', 'putCalendar', 'createCalendar', 'createInvite', 'listMembers', 'revokeMember', 'revokeInvites'] as $action) {
    $request = $make3; $request['action'] = $action; $request['expectedRevision'] = 0;
    $old = api($request, $owner, $ownerKey);
    verify($old[0] === 426 && noTemplatePayload($old), "Legacy $action blocked before document/conflict output");
    $missing = api3($request, $owner, $ownerKey, false);
    verify($missing[0] === 426 && noTemplatePayload($missing), "Missing capability $action blocked");
}
verify(api(['action' => 'getCalendar', 'calendarID' => $v3id], $editor, $editorKey)[0] === 403, 'Unauthorized legacy lookup retains generic denial');
$put3 = ['action' => 'putCalendar', 'calendarID' => $v3id, 'documentSchemaVersion' => 3, 'expectedRevision' => 1, 'document' => $v3doc];
$bad = $put3; unset($bad['documentSchemaVersion']);
verify(api3($bad, $owner, $ownerKey)[0] === 422, 'Missing document schema cannot downgrade');
foreach (['{unknown}', '{date:YYYY}', '{nested{gps:city}}', 'unmatched}', '{'] as $source) {
    $bad = $put3; $bad['document']['clips'][0]['fields']['description'] = $source;
    verify(api3($bad, $owner, $ownerKey)[0] === 422, 'Invalid activated syntax rejected');
}
foreach ([null, 0, 2, true, '1'] as $version) {
    $bad = $put3; $bad['document']['photographers'][0]['copyrightTemplateVersion'] = $version;
    verify(api3($bad, $owner, $ownerKey)[0] === 422, 'Unsupported or mistyped marker rejected');
}
$bad = $put3; unset($bad['document']['clips'][0]['fields']['templateVersions']['description']);
verify(api3($bad, $owner, $ownerKey)[1]['error'] === 'template_activation_lost', 'Accidental activation stripping rejected');
$bad['templateDeactivations'] = [['recordKind' => 'clip', 'recordID' => $v3doc['clips'][0]['id'], 'field' => 'description', 'previousVersion' => 1]];
verify(api3($bad, $owner, $ownerKey)[1]['calendar']['revision'] === 2, 'Explicit matching deactivation accepted');
$stale3 = api3($put3, $owner, $ownerKey);
verify($stale3[0] === 409 && $stale3[1]['calendar']['requiredCapabilities'] === ['metadata-templates-v1'], 'Authorized v3 stale response carries compatibility');
$extra = $bad; $extra['expectedRevision'] = 2;
verify(api3($extra, $owner, $ownerKey)[1]['error'] === 'template_activation_lost', 'Extra deactivation rejected');
$invite3 = api3(['action' => 'createInvite', 'calendarID' => $v3id, 'role' => 'editor', 'rangeStart' => $start, 'rangeEnd' => $end], $owner, $ownerKey)[1]['inviteToken'];
$join3 = ['action' => 'acceptInvite', 'inviteToken' => $invite3, 'deviceName' => 'V3 editor'];
$legacyJoin = api($join3, $editor, $editorKey);
verify($legacyJoin[0] === 426 && noTemplatePayload($legacyJoin), 'Legacy invitation cannot enroll into v3');
verify(api3($join3, $editor, $editorKey, false)[0] === 426, 'Missing capability cannot redeem invitation');
verify(api3($join3, $editor, $editorKey)[0] === 200, 'Capable invite joins selected namespace');
$scoped = api3(['action' => 'getCalendar', 'calendarID' => $v3id], $editor, $editorKey)[1]['calendar'];
verify(count($scoped['document']['clips']) === 1 && isset($scoped['document']['photographers'][0]['copyrightTemplateVersion']), 'Range snapshot preserves activation');
$scopedPut = ['action' => 'putCalendar', 'calendarID' => $v3id, 'documentSchemaVersion' => 3, 'expectedRevision' => 2, 'document' => $scoped['document']];
$scopedPut['document']['clips'][0]['name'] = 'Range edit';
verify(api3($scopedPut, $editor, $editorKey)[0] === 200, 'Range reconstruction accepts marker-preserving edit');
$full3 = api3(['action' => 'getCalendar', 'calendarID' => $v3id], $owner, $ownerKey)[1]['calendar'];
verify(count($full3['document']['clips']) === 3 && isset($full3['document']['clips'][0]['fields']['templateVersions']['keywords']), 'Range reconstruction preserves hidden records and active keywords');
$collisionCreate = $make3; $collisionCreate['calendarID'] = $cid;
verify(api3($collisionCreate, $owner, $ownerKey)[0] === 409, 'V3 cannot reuse legacy identity');
// Run the exact old PHP files against the migrated database, not a simulated decoder.
function rollbackAPI(array $body, string $id, string $key): array {
    $context = stream_context_create(['http' => ['method' => 'POST',
        'header' => "Content-Type: application/json\r\nX-Aagedal-Protocol: 2\r\nX-Aagedal-Device-ID: $id\r\nX-Aagedal-Device-Key: $key\r\n",
        'content' => json_encode($body, JSON_THROW_ON_ERROR), 'ignore_errors' => true, 'timeout' => 10]]);
    $response = file_get_contents('http://legacy-server:8080/index.php', false, $context);
    preg_match('/\s(\d{3})\s/', $http_response_header[0], $match);
    return [(int) $match[1], json_decode($response, true, 32, JSON_THROW_ON_ERROR), $response];
}
verify(!str_contains(rollbackAPI(['action' => 'listCalendars'], $owner, $ownerKey)[2], $v3id), 'Actual old server list cannot see v3');
foreach (['getCalendar', 'putCalendar'] as $action) {
    $request = ['action' => $action, 'calendarID' => $v3id, 'expectedRevision' => 0, 'document' => $doc];
    $oldResponse = rollbackAPI($request, $owner, $ownerKey);
    verify($oldResponse[0] === 403 && noTemplatePayload($oldResponse), 'Actual old server fetch/stale write cannot leak v3');
}
verify(rollbackAPI($join3, $editor, $editorKey)[0] === 403, 'Actual old server cannot redeem v3 invitation');
$legacyCurrent = rollbackAPI(['action' => 'getCalendar', 'calendarID' => $cid], $owner, $ownerKey)[1]['calendar'];
$legacyCurrent['document']['photographers'][0]['creator'] = 'Offline legacy edit';
verify(rollbackAPI(['action' => 'putCalendar', 'calendarID' => $cid, 'expectedRevision' => $legacyCurrent['revision'],
    'document' => $legacyCurrent['document']], $owner, $ownerKey)[0] === 200, 'Old cached literal calendar remains writable after rollback');
verify(api3(['action' => 'getCalendar', 'calendarID' => $v3id], $owner, $ownerKey)[1]['calendar'] === $full3, 'Old cache write cannot alter distinct v3 document or revision');
// Simulate rollback recreating the UUID in the legacy table, then re-upgrade.
$q = $pdo->prepare('INSERT INTO aftpsync_calendars (id,name,time_zone,document) VALUES (?, ?, ?, ?)');
$q->execute([$v3id, 'Rollback collision', 'Europe/Oslo', json_encode($doc)]);
verify(api3(['action' => 'getCalendar', 'calendarID' => $v3id], $reader, $readerKey)[0] === 403, 'Unauthorized collision lookup stays generic');
verify(api3(['action' => 'getCalendar', 'calendarID' => $v3id], $owner, $ownerKey)[1]['error'] === 'namespace_collision', 'Re-upgrade quarantines colliding ID');
verify(!str_contains(api3(['action' => 'listCalendars'], $owner, $ownerKey)[2], $v3id), 'Quarantined ID omitted from listings');
verify(api3($join3, $editor, $editorKey)[1]['error'] === 'namespace_collision', 'Even invite retry is quarantined');
$pdo->prepare('DELETE FROM aftpsync_calendars WHERE id = ?')->execute([$v3id]);
verify(api3(['action' => 'getCalendar', 'calendarID' => $v3id], $owner, $ownerKey)[1]['calendar'] === $full3, 'Collision does not mutate v3 data');
require __DIR__ . "/namespace-race.php";
echo "All template namespace integration checks passed.\n";
