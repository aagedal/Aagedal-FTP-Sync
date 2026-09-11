<?php
declare(strict_types=1);

// Version-one syntax only; source is never expanded or normalized by the server.
function liveTemplateSource(string $source): void {
    if (strlen($source) > 16384) { failLive(422, 'invalid_template'); }
    $tokens = ['photographer', 'gps:city', 'gps:country', 'persons',
        'date:YYYY-MM-DD', 'date:yyyy-MM-dd', 'dateCaptured:YYYY-MM-DD', 'dateCaptured:yyyy-MM-dd'];
    for ($i = 0, $length = strlen($source); $i < $length; $i++) {
        $ch = $source[$i];
        if (($ch === '{' || $ch === '}') && $i + 1 < $length && $source[$i + 1] === $ch) { $i++; continue; }
        if ($ch === '}') { failLive(422, 'invalid_template'); }
        if ($ch !== '{') { continue; }
        $end = strpos($source, '}', $i + 1);
        if ($end === false || !in_array(substr($source, $i + 1, $end - $i - 1), $tokens, true)) { failLive(422, 'invalid_template'); }
        $i = $end;
    }
}
function liveTemplateMarkers(array $input, array &$output): void {
    if (!array_key_exists('templateVersions', $input)) { return; }
    $markers = $input['templateVersions'];
    if (!is_array($markers) || !$markers || array_is_list($markers)) { failLive(422, 'invalid_template_marker'); }
    liveKeys($markers, ['headline', 'description', 'keywords']);
    foreach ($markers as $field => $version) {
        if ($version !== 1) { failLive(422, 'invalid_template_marker'); }
        foreach ($field === 'keywords' ? $output[$field] : [$output[$field]] as $source) { liveTemplateSource($source); }
    }
    $output['templateVersions'] = $markers;
}
function liveActiveRecords(array $document): array {
    $records = [];
    foreach ($document['photographers'] as $p) {
        $records['photographer:' . $p['id']] = isset($p['copyrightTemplateVersion']) ? ['copyrightNotice' => $p['copyrightTemplateVersion']] : [];
    }
    foreach ($document['clips'] as $c) { $records['clip:' . $c['id']] = $c['fields']['templateVersions'] ?? []; }
    return $records;
}
function liveTemplateTransitions(array $before, array $after, mixed $transitions): void {
    $expected = []; $provided = [];
    $old = liveActiveRecords($before); $new = liveActiveRecords($after);
    foreach ($old as $record => $markers) {
        if (!array_key_exists($record, $new)) { continue; }
        foreach ($markers as $field => $version) {
            if (!isset($new[$record][$field])) { $expected[$record . ':' . $field] = $version; }
        }
    }
    foreach (liveArray($transitions, 10000) as $transition) {
        if (!is_array($transition)) { failLive(422, 'template_activation_lost'); }
        liveKeys($transition, ['recordKind', 'recordID', 'field', 'previousVersion']);
        $kind = $transition['recordKind'] ?? null; $field = $transition['field'] ?? null;
        if (!in_array($kind, ['clip', 'photographer'], true) || !is_string($field)) { failLive(422, 'template_activation_lost'); }
        $key = $kind . ':' . liveID($transition['recordID'] ?? null) . ':' . $field;
        if (isset($provided[$key]) || ($transition['previousVersion'] ?? null) !== 1) { failLive(422, 'template_activation_lost'); }
        $provided[$key] = 1;
    }
    ksort($expected); ksort($provided);
    if ($expected !== $provided) { failLive(422, 'template_activation_lost'); }
}
