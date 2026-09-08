-- Import into a dedicated database using phpMyAdmin or the MySQL CLI.
-- This table is only for the hosting check. No calendar schema is installed yet.
CREATE TABLE IF NOT EXISTS aftpsync_hosting_probe (
    probe_id CHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    payload VARCHAR(255) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
