-- sensors.readings — main time-series table
-- Engine: ReplacingMergeTree(version) for idempotent deduplication without DELETE mutations
--   rule: insert-mutation-avoid-delete
-- ORDER BY (sensor_id, timestamp): sensor_id is the primary equality filter, timestamp is the range filter
--   rule: schema-pk-cardinality-order, schema-pk-filter-on-orderby
-- PARTITION BY toYYYYMM(timestamp): monthly partitions, enables TTL and partition drops
--   rule: schema-partition-low-cardinality, schema-partition-lifecycle
-- No Nullable columns: BMP180 sensors don't emit particulate fields — DEFAULT 0 means "not measured"
--   rule: schema-types-avoid-nullable
CREATE TABLE IF NOT EXISTS sensors.readings
(
    -- Identity
    sensor_id          UInt32,                              -- rule: schema-types-minimize-bitwidth
    sensor_type        LowCardinality(String),              -- rule: schema-types-lowcardinality (~10 distinct values)
    location           UInt32,
    lat                Float32,
    lon                Float32,

    -- Time
    timestamp          DateTime,                            -- rule: schema-types-native-types (not String)

    -- Particulate matter (SDS011 / PMS sensors — absent in BMP180 data, defaults to 0)
    P1                 Float32   DEFAULT 0,                 -- PM10 µg/m³
    P2                 Float32   DEFAULT 0,                 -- PM2.5 µg/m³
    P0                 Float32   DEFAULT 0,                 -- PM1 µg/m³
    durP1              Float32   DEFAULT 0,
    ratioP1            Float32   DEFAULT 0,
    durP2              Float32   DEFAULT 0,
    ratioP2            Float32   DEFAULT 0,

    -- Atmospheric (BMP180 native fields)
    pressure           Float32   DEFAULT 0,                 -- Pa
    altitude           Float32   DEFAULT 0,                 -- m
    pressure_sealevel  Float32   DEFAULT 0,                 -- Pa
    temperature        Float32   DEFAULT 0,                 -- °C
    humidity           Float32   DEFAULT 0,                 -- %

    -- Deduplication: higher version wins during ReplacingMergeTree merge
    -- Seed rows get toUnixTimestamp(now()); Kafka rows (M3) use message timestamp (always higher)
    version            UInt64    DEFAULT toUnixTimestamp(now()),

    -- Materialized derived column: stored at insert time, zero query overhead
    date               Date      MATERIALIZED toDate(timestamp)
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (sensor_id, timestamp)
SETTINGS index_granularity = 8192;

-- Data skipping index on sensor_type
-- TYPE set(50): stores distinct values per granule block, correct for low-cardinality equality filters
-- GRANULARITY 4: covers 4 × 8192 = 32768 rows per skip-index entry
-- (not bloom_filter — that's for high-cardinality; not minmax — that's for numerics)
ALTER TABLE sensors.readings
    ADD INDEX IF NOT EXISTS idx_sensor_type
        (sensor_type) TYPE set(50) GRANULARITY 4;
