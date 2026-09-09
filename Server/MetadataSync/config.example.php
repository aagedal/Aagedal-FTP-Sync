<?php
// Keep the real config.php outside the public web directory.
return [
    'database_host' => 'MYSQL_HOST_FROM_YOUR_PROVIDER',
    'database_port' => 3306,
    'database_name' => 'YOUR_DATABASE_NAME',
    'database_user' => 'YOUR_DATABASE_USER',
    'database_password' => 'YOUR_DATABASE_PASSWORD',
    // SHA-256 of a randomly generated 32-byte hex key. Never use this placeholder.
    'setup_key_sha256' => 'REPLACE_WITH_SHA256_HASH',
    // Set false after the hosting trial; public GET remains available.
    'hosting_checks_enabled' => true,
    // Enable only to register the first owner device, then set false.
    'bootstrap_enabled' => false,
];
