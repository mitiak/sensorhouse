-- Materialized View: incremental pre-aggregation from readings → readings_hourly
-- rule: query-mv-incremental — fires on every INSERT block into sensors.readings
--
-- Uses TO target syntax (push to existing table) rather than auto-creating target.
-- -State combinators must match AggregateFunction(fn, type) declarations exactly:
--   avgState(temperature) where temperature is Float32 → AggregateFunction(avg, Float32) ✓
--
-- Query pattern for Grafana/API:
--   SELECT hour, avgMerge(avg_temp) AS temp, sumMerge(sample_count) AS n
--   FROM sensors.readings_hourly
--   WHERE sensor_id = 42 AND hour >= '2019-06-01'
--   GROUP BY hour ORDER BY hour
CREATE MATERIALIZED VIEW IF NOT EXISTS sensors.readings_hourly_mv
TO sensors.readings_hourly
AS
SELECT
    sensor_id,
    sensor_type,
    toStartOfHour(timestamp)    AS hour,
    avgState(temperature)       AS avg_temp,
    avgState(humidity)          AS avg_humidity,
    avgState(pressure)          AS avg_pressure,
    avgState(P1)                AS avg_P1,
    avgState(P2)                AS avg_P2,
    anyState(lat)               AS lat,
    anyState(lon)               AS lon,
    sumState(toUInt64(1))       AS sample_count
FROM sensors.readings
GROUP BY sensor_id, sensor_type, hour;
