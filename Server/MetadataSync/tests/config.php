<?php
// Disposable local test database only. Never deploy this file.
return [
    'database_host' => 'database',
    'database_port' => 3306,
    'database_name' => 'hosting_test',
    'database_user' => 'hosting_test',
    'database_password' => 'local-test-only',
    'setup_key_sha256' => hash('sha256', str_repeat('a', 64)),
    'hosting_checks_enabled' => true,
];
