-- sensors.readings_hourly — pre-aggregated hourly rollup
-- Engine: AggregatingMergeTree (not SummingMergeTree) because:
--   SummingMergeTree cannot correctly re-merge pre-averaged Float32 values across parts.
--   AggregatingMergeTree stores avgState (sum + count binary blob) and merges exactly.
--   rule: query-mv-incremental
-- ORDER BY (sensor_id, hour): mirrors readings table pattern
--   rule: schema-pk-cardinality-order
-- sample_count uses AggregateFunction(sum, UInt64) — plain UInt64 would NOT accumulate
--   across parts in AggregatingMergeTree (only AggregateFunction columns merge correctly)
CREATE TABLE IF NOT EXISTS sensors.readings_hourly
(
    sensor_id     UInt32,
    sensor_type   LowCardinality(String),                   -- rule: schema-types-lowcardinality
    hour          DateTime,                                  -- rule: schema-types-native-types

    -- AggregateFunction columns store intermediate merge states
    -- At query time use: avgMerge(avg_temp), sumMerge(sample_count)
    avg_temp      AggregateFunction(avg, Float32),
    avg_humidity  AggregateFunction(avg, Float32),
    avg_pressure  AggregateFunction(avg, Float32),
    avg_P1        AggregateFunction(avg, Float32),
    avg_P2        AggregateFunction(avg, Float32),

    -- any() is stable for geolocation (sensor position doesn't change)
    lat           AggregateFunction(any, Float32),
    lon           AggregateFunction(any, Float32),

    -- Must be AggregateFunction to accumulate correctly across parts
    sample_count  AggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(hour)                                 -- mirrors readings partition scheme
ORDER BY (sensor_id, hour)
SETTINGS index_granularity = 8192;
