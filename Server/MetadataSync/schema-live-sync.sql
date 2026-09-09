-- Additive migration. Import after schema.sql. Requires InnoDB.
CREATE TABLE IF NOT EXISTS aftpsync_devices (
 id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 token_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 name VARCHAR(100) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS aftpsync_bootstrap (
 id INT PRIMARY KEY, device_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NULL
) ENGINE=InnoDB;
INSERT IGNORE INTO aftpsync_bootstrap (id) VALUES (1);
CREATE TABLE IF NOT EXISTS aftpsync_calendars (
 id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 name VARCHAR(100) NOT NULL, time_zone VARCHAR(100) NOT NULL,
 revision BIGINT NOT NULL DEFAULT 1, document LONGTEXT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS aftpsync_members (
 calendar_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 device_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 role VARCHAR(10) NOT NULL, range_start BIGINT NULL, range_end BIGINT NULL,
 PRIMARY KEY (calendar_id, device_id),
 FOREIGN KEY (calendar_id) REFERENCES aftpsync_calendars(id),
 FOREIGN KEY (device_id) REFERENCES aftpsync_devices(id)
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS aftpsync_invites (
 token_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 calendar_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 role VARCHAR(10) NOT NULL, range_start BIGINT NULL, range_end BIGINT NULL,
 expires_at BIGINT NOT NULL, redeemed_by CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NULL,
 FOREIGN KEY (calendar_id) REFERENCES aftpsync_calendars(id)
) ENGINE=InnoDB;
