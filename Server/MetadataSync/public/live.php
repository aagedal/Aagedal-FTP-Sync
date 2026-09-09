<?php
declare(strict_types=1);

// Loaded by index.php after its private configuration. No secrets in this file.
function liveReply(int $status, array $data = []): never {
    http_response_code($status);
    echo json_encode(['service' => 'aagedal-metadata-sync', 'protocolVersion' => 2] + $data,
        JSON_THROW_ON_ERROR | JSON_UNESCAPED_UNICODE);
    exit;
}
function failLive(int $status, string $error): never { liveReply($status, ['error' => $error]); }
function liveID(mixed $id): string {
    if (!is_string($id) || !preg_match('/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i', $id)) {
        failLive(400, 'invalid_id');
    }
    return strtoupper($id);
}
function liveText(mixed $value, int $limit, bool $required = false): string {
    if (!is_string($value) || strlen($value) > $limit || str_contains($value, "\0")
        || ($required && trim($value) === '')) { failLive(400, 'invalid_text'); }
    return $value;
}
function liveNumber(mixed $value): int|float {
    if ((!is_int($value) && !is_float($value)) || !is_finite((float) $value)) { failLive(400, 'invalid_number'); }
    return $value;
}
function liveDate(mixed $value): int {
    $value = liveNumber($value);
    if ($value < 0 || $value > 4102444800000 || floor($value) != $value) { failLive(400, 'invalid_date'); }
    return (int) $value;
}
function liveKeys(array $value, array $allowed): void {
    if (array_diff(array_keys($value), $allowed)) { failLive(400, 'unknown_fields'); }
}
function liveArray(mixed $value, int $limit): array {
    if (!is_array($value) || !array_is_list($value) || count($value) > $limit) { failLive(400, 'invalid_list'); }
    return $value;
}
function liveDocument(mixed $input): array {
    if (!is_array($input)) { failLive(400, 'invalid_document'); }
    liveKeys($input, ['photographers', 'photographerTracks', 'clips']);
    $photos = []; $prefixes = [];
    foreach (liveArray($input['photographers'] ?? null, 500) as $p) {
        if (!is_array($p)) { failLive(400, 'invalid_photographer'); }
        liveKeys($p, ['id', 'name', 'filenamePrefix', 'creator', 'copyrightNotice']);
        $id = liveID($p['id'] ?? null);
        if (isset($photos[$id])) { failLive(400, 'duplicate_id'); }
        $photos[$id] = ['id' => $id, 'name' => liveText($p['name'] ?? null, 400),
            'filenamePrefix' => liveText($p['filenamePrefix'] ?? null, 400),
            'creator' => liveText($p['creator'] ?? null, 400),
            'copyrightNotice' => liveText($p['copyrightNotice'] ?? null, 2000)];
        foreach (explode(',', $p['filenamePrefix']) as $prefix) {
            $prefix = strtoupper(trim($prefix));
            if ($prefix !== '' && isset($prefixes[$prefix]) && $prefixes[$prefix] !== $id) { failLive(422, 'duplicate_prefix'); }
            $prefixes[$prefix] = $id;
        }
    }
    $clips = []; $byPhotographer = [];
    foreach (liveArray($input['clips'] ?? null, 2000) as $c) {
        if (!is_array($c)) { failLive(400, 'invalid_clip'); }
        liveKeys($c, ['id', 'photographerID', 'name', 'startsAt', 'endsAt', 'fields', 'gpsPosition']);
        $id = liveID($c['id'] ?? null); $pid = liveID($c['photographerID'] ?? null);
        if (isset($clips[$id]) || !isset($photos[$pid])) { failLive(422, 'invalid_reference'); }
        $start = liveDate($c['startsAt'] ?? null); $end = liveDate($c['endsAt'] ?? null);
        if ($end <= $start) { failLive(422, 'invalid_interval'); }
        $fields = $c['fields'] ?? null;
        if (!is_array($fields)) { failLive(400, 'invalid_fields'); }
        liveKeys($fields, ['headline', 'description', 'keywords']);
        $fields = ['headline' => liveText($fields['headline'] ?? null, 4000),
            'description' => liveText($fields['description'] ?? null, 16000),
            'keywords' => array_map(fn($k) => liveText($k, 400), liveArray($fields['keywords'] ?? null, 100))];
        $clip = ['id' => $id, 'photographerID' => $pid, 'name' => liveText($c['name'] ?? null, 1000, true),
            'startsAt' => $start, 'endsAt' => $end, 'fields' => $fields];
        if (isset($c['gpsPosition'])) {
            $g = $c['gpsPosition'];
            if (!is_array($g)) { failLive(400, 'invalid_location'); }
            liveKeys($g, ['latitude', 'longitude', 'altitudeMeters', 'label']);
            $g = ['latitude' => liveNumber($g['latitude'] ?? null), 'longitude' => liveNumber($g['longitude'] ?? null)]
                + array_intersect_key($g, array_flip(['altitudeMeters', 'label']));
            if (abs($g['latitude']) > 90 || abs($g['longitude']) > 180) { failLive(400, 'invalid_location'); }
            if (isset($g['altitudeMeters'])) { liveNumber($g['altitudeMeters']); }
            if (isset($g['label'])) { liveText($g['label'], 1000); }
            $clip['gpsPosition'] = array_filter($g, fn($v) => $v !== null);
        }
        $clips[$id] = $clip; $byPhotographer[$pid][] = $clip;
    }
    foreach ($byPhotographer as $items) {
        usort($items, fn($a, $b) => $a['startsAt'] <=> $b['startsAt']);
        for ($i = 1; $i < count($items); $i++) {
            if ($items[$i-1]['endsAt'] > $items[$i]['startsAt']) { failLive(422, 'overlapping_clips'); }
        }
    }
    $tracks = []; $seenTracks = [];
    foreach (liveArray($input['photographerTracks'] ?? null, 5000) as $t) {
        if (!is_array($t)) { failLive(400, 'invalid_track'); }
        liveKeys($t, ['photographerID', 'date']);
        $pid = liveID($t['photographerID'] ?? null); $d = $t['date'] ?? null;
        if (!is_array($d)) { failLive(400, 'invalid_date'); }
        liveKeys($d, ['year', 'month', 'day']);
        foreach (['year', 'month', 'day'] as $key) { if (!is_int($d[$key] ?? null)) { failLive(400, 'invalid_date'); } }
        if ($d['year'] < 1970 || $d['year'] > 2099 || !checkdate($d['month'], $d['day'], $d['year']) || !isset($photos[$pid])) { failLive(422, 'invalid_track'); }
        $d = ['year' => $d['year'], 'month' => $d['month'], 'day' => $d['day']];
        $key = $pid . ':' . implode('-', $d);
        if (isset($seenTracks[$key])) { failLive(400, 'duplicate_track'); }
        $seenTracks[$key] = true; $tracks[] = ['photographerID' => $pid, 'date' => $d];
    }
    ksort($photos); ksort($clips);
    return ['photographers' => array_values($photos), 'photographerTracks' => $tracks, 'clips' => array_values($clips)];
}
function trackVisible(array $t, array $member, string $zone): bool {
    if ($member['range_start'] === null) { return true; }
    $d = $t['date'];
    $day = new DateTimeImmutable(sprintf('%04d-%02d-%02d', $d['year'], $d['month'], $d['day']), new DateTimeZone($zone));
    return $day->getTimestamp() * 1000 >= $member['range_start']
        && $day->modify('+1 day')->getTimestamp() * 1000 <= $member['range_end'];
}
function visibleDocument(array $doc, array $member, string $zone): array {
    if ($member['range_start'] === null) { return $doc; }
    $doc['clips'] = array_values(array_filter($doc['clips'], fn($c) =>
        $c['startsAt'] >= $member['range_start'] && $c['endsAt'] <= $member['range_end']));
    $doc['photographerTracks'] = array_values(array_filter($doc['photographerTracks'], fn($t) => trackVisible($t, $member, $zone)));
    $ids = array_merge(array_column($doc['clips'], 'photographerID'), array_column($doc['photographerTracks'], 'photographerID'));
    $doc['photographers'] = array_values(array_filter($doc['photographers'], fn($p) => in_array($p['id'], $ids, true)));
    return $doc;
}
function snapshot(array $calendar, array $member): array {
    return ['id' => $calendar['id'], 'name' => $calendar['name'], 'timeZone' => $calendar['time_zone'],
        'revision' => (int) $calendar['revision'], 'role' => $member['role'],
        'rangeStart' => $member['range_start'] === null ? null : (int) $member['range_start'],
        'rangeEnd' => $member['range_end'] === null ? null : (int) $member['range_end'],
        'document' => visibleDocument(json_decode($calendar['document'], true, 32, JSON_THROW_ON_ERROR), $member, $calendar['time_zone'])];
}
function liveQuery(PDO $pdo, string $sql, array $params = []): PDOStatement {
    $q = $pdo->prepare($sql); $q->execute($params); return $q;
}
function liveRun(array $config): never {
    $pdo = null;
    try {
        $body = file_get_contents('php://input', false, null, 0, 1048577);
        if ($body === false || strlen($body) > 1048576) { failLive(413, 'request_too_large'); }
        try { $r = json_decode($body, true, 32, JSON_THROW_ON_ERROR); }
        catch (JsonException) { failLive(400, 'invalid_request'); }
        if (!is_array($r) || !is_string($r['action'] ?? null)) { failLive(400, 'invalid_request'); }
        $host = $config['database_host'] ?? ''; $db = $config['database_name'] ?? '';
        foreach ([$host, $db] as $v) {
            if (!is_string($v) || $v === '' || preg_match('/[;\x00-\x20]/', $v)) { failLive(503, 'invalid_configuration'); }
        }
        $port = filter_var($config['database_port'] ?? 3306, FILTER_VALIDATE_INT);
        if (!$port || $port < 1 || $port > 65535) { failLive(503, 'invalid_configuration'); }
        $pdo = new PDO("mysql:host=$host;port=$port;dbname=$db;charset=utf8mb4", $config['database_user'], $config['database_password'],
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_EMULATE_PREPARES => false, PDO::ATTR_TIMEOUT => 5]);
        $pdo->exec('SET SESSION innodb_lock_wait_timeout = 5');
        $id = liveID($_SERVER['HTTP_X_AAGEDAL_DEVICE_ID'] ?? null);
        $token = $_SERVER['HTTP_X_AAGEDAL_DEVICE_KEY'] ?? '';
        if (!preg_match('/\A[a-f0-9]{64}\z/', $token)) { failLive(401, 'unauthorized'); }
        $hash = hash('sha256', $token);
        $device = liveQuery($pdo, 'SELECT * FROM aftpsync_devices WHERE id = ?', [$id])->fetch(PDO::FETCH_ASSOC);
        if ($device && !hash_equals($device['token_hash'], $hash)) { failLive(401, 'unauthorized'); }
        if ($r['action'] === 'bootstrap') {
            $pdo->beginTransaction();
            $owner = liveQuery($pdo, 'SELECT device_id FROM aftpsync_bootstrap WHERE id = 1 FOR UPDATE')->fetchColumn();
            if ($owner === $id && $device) { $pdo->commit(); liveReply(200); }
            $key = $_SERVER['HTTP_X_AAGEDAL_SETUP_KEY'] ?? '';
            $expected = $config['setup_key_sha256'] ?? '';
            if ($owner !== null || ($config['bootstrap_enabled'] ?? false) !== true
                || !is_string($expected) || !preg_match('/\A[a-f0-9]{64}\z/', $expected)
                || !preg_match('/\A[a-f0-9]{64}\z/', $key) || !hash_equals($expected, hash('sha256', $key))) { failLive(403, 'bootstrap_disabled'); }
            liveQuery($pdo, 'INSERT INTO aftpsync_devices (id, token_hash, name) VALUES (?, ?, ?)', [$id, $hash, liveText($r['deviceName'] ?? '', 100, true)]);
            liveQuery($pdo, 'UPDATE aftpsync_bootstrap SET device_id = ? WHERE id = 1', [$id]);
            $pdo->commit(); liveReply(200);
        }
        if ($r['action'] === 'acceptInvite') {
            $inviteToken = $r['inviteToken'] ?? '';
            if (!is_string($inviteToken) || !preg_match('/\A[a-f0-9]{64}\z/', $inviteToken)) { failLive(401, 'invalid_invite'); }
            $pdo->beginTransaction();
            $invitedCalendar = liveQuery($pdo, 'SELECT calendar_id FROM aftpsync_invites WHERE token_hash = ?', [hash('sha256', $inviteToken)])->fetchColumn();
            if (!$invitedCalendar) { failLive(403, 'invalid_invite'); }
            liveQuery($pdo, 'SELECT id FROM aftpsync_calendars WHERE id = ? FOR UPDATE', [$invitedCalendar]);
            $invite = liveQuery($pdo, 'SELECT * FROM aftpsync_invites WHERE token_hash = ? FOR UPDATE', [hash('sha256', $inviteToken)])->fetch(PDO::FETCH_ASSOC);
            if (!$invite || ($invite['redeemed_by'] !== null && $invite['redeemed_by'] !== $id)
                || ($invite['redeemed_by'] === null && $invite['expires_at'] < time())) { failLive(403, 'invalid_invite'); }
            if ($invite['redeemed_by'] === $id && $device) { $pdo->commit(); liveReply(200); }
            if (!$device) { liveQuery($pdo, 'INSERT INTO aftpsync_devices (id, token_hash, name) VALUES (?, ?, ?)', [$id, $hash, liveText($r['deviceName'] ?? '', 100, true)]); }
            if (liveQuery($pdo, 'SELECT role FROM aftpsync_members WHERE calendar_id = ? AND device_id = ?', [$invite['calendar_id'], $id])->fetchColumn()) { failLive(409, 'already_member'); }
            liveQuery($pdo, 'INSERT INTO aftpsync_members VALUES (?, ?, ?, ?, ?)', [$invite['calendar_id'], $id, $invite['role'], $invite['range_start'], $invite['range_end']]);
            liveQuery($pdo, 'UPDATE aftpsync_invites SET redeemed_by = ? WHERE token_hash = ?', [$id, $invite['token_hash']]);
            $pdo->commit(); liveReply(200);
        }
        if (!$device) { failLive(401, 'unauthorized'); }
        if ($r['action'] === 'listCalendars') {
            $rows = liveQuery($pdo, 'SELECT c.id, c.name, c.time_zone AS timeZone, m.role FROM aftpsync_calendars c JOIN aftpsync_members m ON m.calendar_id = c.id WHERE m.device_id = ? ORDER BY c.name', [$id])->fetchAll(PDO::FETCH_ASSOC);
            liveReply(200, ['calendars' => $rows]);
        }
        $cid = liveID($r['calendarID'] ?? null);
        if ($r['action'] === 'createCalendar') {
            $doc = liveDocument($r['document'] ?? null);
            $name = liveText($r['name'] ?? null, 100, true); $zone = liveText($r['timeZone'] ?? null, 100, true);
            if (!in_array($zone, DateTimeZone::listIdentifiers(DateTimeZone::ALL_WITH_BC), true)) { failLive(400, 'invalid_time_zone'); }
            $pdo->beginTransaction();
            // Serialize creation per device, including retries after an uncertain response.
            liveQuery($pdo, 'SELECT id FROM aftpsync_devices WHERE id = ? FOR UPDATE', [$id]);
            $existing = liveQuery($pdo, 'SELECT role FROM aftpsync_members WHERE calendar_id = ? AND device_id = ?', [$cid, $id])->fetchColumn();
            if ($existing !== 'owner') {
                if ($existing || liveQuery($pdo, 'SELECT id FROM aftpsync_calendars WHERE id = ?', [$cid])->fetchColumn()) { failLive(409, 'id_in_use'); }
                if ((int) liveQuery($pdo, "SELECT COUNT(*) FROM aftpsync_members WHERE device_id = ? AND role = 'owner'", [$id])->fetchColumn() >= 100) { failLive(422, 'calendar_limit'); }
                liveQuery($pdo, 'INSERT INTO aftpsync_calendars (id, name, time_zone, document) VALUES (?, ?, ?, ?)', [$cid, $name, $zone, json_encode($doc, JSON_THROW_ON_ERROR)]);
                liveQuery($pdo, "INSERT INTO aftpsync_members VALUES (?, ?, 'owner', NULL, NULL)", [$cid, $id]);
            }
            $pdo->commit();
        }
        $pdo->beginTransaction();
        // Every membership mutation and calendar write takes the same calendar lock.
        $calendar = liveQuery($pdo, 'SELECT * FROM aftpsync_calendars WHERE id = ? FOR UPDATE', [$cid])->fetch(PDO::FETCH_ASSOC);
        $member = liveQuery($pdo, 'SELECT * FROM aftpsync_members WHERE calendar_id = ? AND device_id = ?', [$cid, $id])->fetch(PDO::FETCH_ASSOC);
        if (!$calendar || !$member) { failLive(403, 'access_denied'); }
        if ($r['action'] === 'getCalendar' || $r['action'] === 'createCalendar') {
            $pdo->commit(); liveReply(200, ['calendar' => snapshot($calendar, $member)]);
        }
        if ($r['action'] === 'putCalendar') {
            if ($member['role'] === 'reader') { failLive(403, 'read_only'); }
            if (!is_int($r['expectedRevision'] ?? null) || $r['expectedRevision'] !== (int) $calendar['revision']) {
                $pdo->commit(); liveReply(409, ['error' => 'revision_conflict', 'calendar' => snapshot($calendar, $member)]);
            }
            $next = liveDocument($r['document'] ?? null);
            if ($member['range_start'] !== null) {
                $full = json_decode($calendar['document'], true, 32, JSON_THROW_ON_ERROR);
                $visible = visibleDocument($full, $member, $calendar['time_zone']);
                if ($next['photographers'] !== $visible['photographers']) { failLive(403, 'range_profiles_read_only'); }
                if (visibleDocument($next, $member, $calendar['time_zone'])['clips'] !== $next['clips']
                    || count(visibleDocument($next, $member, $calendar['time_zone'])['photographerTracks']) !== count($next['photographerTracks'])) { failLive(403, 'outside_range'); }
                $visibleIDs = array_column($visible['clips'], 'id');
                $hidden = array_values(array_filter($full['clips'], fn($c) => !in_array($c['id'], $visibleIDs, true)));
                if (array_intersect(array_column($hidden, 'id'), array_column($next['clips'], 'id'))) { failLive(403, 'outside_range'); }
                $next = liveDocument(['photographers' => $full['photographers'], 'clips' => array_merge($hidden, $next['clips']),
                    'photographerTracks' => array_merge(array_values(array_filter($full['photographerTracks'], fn($t) => !trackVisible($t, $member, $calendar['time_zone']))), $next['photographerTracks'])]);
            }
            $encoded = json_encode($next, JSON_THROW_ON_ERROR | JSON_UNESCAPED_UNICODE);
            if (strlen($encoded) > 1000000) { failLive(413, 'calendar_too_large'); }
            liveQuery($pdo, 'UPDATE aftpsync_calendars SET document = ?, revision = revision + 1 WHERE id = ?', [$encoded, $cid]);
            $calendar['document'] = $encoded; $calendar['revision']++;
            $pdo->commit(); liveReply(200, ['calendar' => snapshot($calendar, $member)]);
        }
        if ($member['role'] !== 'owner') { failLive(403, 'owner_required'); }
        if ($r['action'] === 'createInvite') {
            $role = $r['role'] ?? '';
            if (!in_array($role, ['editor', 'reader'], true)) { failLive(400, 'invalid_role'); }
            $start = isset($r['rangeStart']) ? liveDate($r['rangeStart']) : null;
            $end = isset($r['rangeEnd']) ? liveDate($r['rangeEnd']) : null;
            if (($start === null) !== ($end === null) || ($start !== null && $end <= $start)) { failLive(400, 'invalid_range'); }
            liveQuery($pdo, 'DELETE FROM aftpsync_invites WHERE calendar_id = ? AND expires_at < ?', [$cid, time()]);
            if ((int) liveQuery($pdo, 'SELECT COUNT(*) FROM aftpsync_invites WHERE calendar_id = ?', [$cid])->fetchColumn() >= 100) { failLive(422, 'invite_limit'); }
            $invite = bin2hex(random_bytes(32));
            liveQuery($pdo, 'INSERT INTO aftpsync_invites VALUES (?, ?, ?, ?, ?, ?, NULL)', [hash('sha256', $invite), $cid, $role, $start, $end, time() + 86400]);
            $pdo->commit(); liveReply(200, ['inviteToken' => $invite]);
        }
        if ($r['action'] === 'listMembers') {
            $members = liveQuery($pdo, 'SELECT d.id, d.name, m.role FROM aftpsync_members m JOIN aftpsync_devices d ON d.id = m.device_id WHERE m.calendar_id = ?', [$cid])->fetchAll(PDO::FETCH_ASSOC);
            $pdo->commit(); liveReply(200, ['members' => $members]);
        }
        if ($r['action'] === 'revokeMember') {
            $target = liveID($r['deviceID'] ?? null);
            if ($target === $id) { failLive(400, 'cannot_revoke_owner'); }
            liveQuery($pdo, 'DELETE FROM aftpsync_members WHERE calendar_id = ? AND device_id = ?', [$cid, $target]);
            // Invalidate redeemed invitations too, preventing replay from restoring access.
            liveQuery($pdo, 'DELETE FROM aftpsync_invites WHERE calendar_id = ? AND redeemed_by = ?', [$cid, $target]);
            $pdo->commit(); liveReply(200);
        }
        if ($r['action'] === 'revokeInvites') {
            liveQuery($pdo, 'DELETE FROM aftpsync_invites WHERE calendar_id = ?', [$cid]);
            $pdo->commit(); liveReply(200);
        }
        failLive(400, 'unknown_action');
    } catch (Throwable $e) {
        if ($pdo instanceof PDO && $pdo->inTransaction()) { $pdo->rollBack(); }
        error_log('Aagedal metadata sync: request failed. Check private configuration and live sync schema.');
        failLive(503, 'sync_unavailable');
    }
}
