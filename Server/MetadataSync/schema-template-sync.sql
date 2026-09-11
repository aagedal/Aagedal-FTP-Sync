-- Additive protocol 3 namespace. Import AFTER schema-live-sync.sql; never copy legacy records here.
CREATE TABLE IF NOT EXISTS aftpsync_v3_calendars (
 id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 name VARCHAR(100) NOT NULL, time_zone VARCHAR(100) NOT NULL,
 revision BIGINT NOT NULL DEFAULT 1, document LONGTEXT NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
CREATE TABLE IF NOT EXISTS aftpsync_v3_members (
 calendar_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 device_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 role VARCHAR(10) NOT NULL, range_start BIGINT NULL, range_end BIGINT NULL,
 PRIMARY KEY (calendar_id, device_id),
 FOREIGN KEY (calendar_id) REFERENCES aftpsync_v3_calendars(id),
 FOREIGN KEY (device_id) REFERENCES aftpsync_devices(id)
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS aftpsync_v3_invites (
 token_hash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 calendar_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 role VARCHAR(10) NOT NULL, range_start BIGINT NULL, range_end BIGINT NULL,
 expires_at BIGINT NOT NULL, redeemed_by CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NULL,
 FOREIGN KEY (calendar_id) REFERENCES aftpsync_v3_calendars(id)
) ENGINE=InnoDB;
