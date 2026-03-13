-- Milestone 4: Add 5-year TTL to auto-expire old sensor data during background merges.
-- Safe to apply even on fresh data — ClickHouse only enforces TTL during merges.
ALTER TABLE sensors.readings
    MODIFY TTL date + INTERVAL 10 YEAR;
