-- Fires for every batch ClickHouse polls from Kafka.
-- Normalises nulls, parses timestamp string, and writes to sensors.readings.
CREATE MATERIALIZED VIEW IF NOT EXISTS sensors.readings_kafka_mv
TO sensors.readings
AS
SELECT
    sensor_id,
    sensor_type,
    location,
    coalesce(lat, 0.0)                      AS lat,
    coalesce(lon, 0.0)                      AS lon,
    parseDateTimeBestEffort(ts)             AS timestamp,
    coalesce(P1, 0.0)                       AS P1,
    coalesce(P2, 0.0)                       AS P2,
    coalesce(P0, 0.0)                       AS P0,
    0.0                                     AS durP1,
    0.0                                     AS ratioP1,
    0.0                                     AS durP2,
    0.0                                     AS ratioP2,
    coalesce(pressure, 0.0)                 AS pressure,
    coalesce(altitude, 0.0)                 AS altitude,
    coalesce(pressure_sealevel, 0.0)        AS pressure_sealevel,
    coalesce(temperature, 0.0)              AS temperature,
    coalesce(humidity, 0.0)                 AS humidity,
    version
FROM sensors.readings_kafka
WHERE sensor_id > 0
  AND length(sensor_type) > 0
  AND parseDateTimeBestEffort(ts) > toDateTime('2010-01-01');
