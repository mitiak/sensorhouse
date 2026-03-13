-- Load June 2019 BMP180 sensor data from the public Sensor.Community S3 dataset.
-- Source: Sensor.Community (formerly Luftdaten) — environmental monitoring network
-- Format: CSVWithNames, semicolon-delimited, Zstandard-compressed
--
-- Explicit column list (not SELECT *):
--   BMP180 CSV does not contain P1/P2/P0 particulate columns.
--   Omitted columns default to 0 per table definition (no Nullable needed).
--
-- version = toUnixTimestamp(now()):
--   All seed rows get the same version (current epoch seconds).
--   Kafka rows in M3 use their message timestamps (always larger than seed version),
--   so Kafka updates will correctly win during ReplacingMergeTree merges.
INSERT INTO sensors.readings
    (sensor_id, sensor_type, location, lat, lon, timestamp,
     pressure, altitude, pressure_sealevel, temperature, version)
SELECT
    sensor_id,
    sensor_type,
    location,
    lat,
    lon,
    timestamp,
    pressure,
    altitude,
    pressure_sealevel,
    temperature,
    toUnixTimestamp(now()) AS version
FROM s3(
    'https://clickhouse-public-datasets.s3.eu-central-1.amazonaws.com/sensors/monthly/2019-06_bmp180.csv.zst',
    'CSVWithNames'
)
SETTINGS
    format_csv_delimiter            = ';',
    input_format_allow_errors_ratio = 0.5,
    input_format_allow_errors_num   = 1000,
    date_time_input_format          = 'best_effort',
    max_insert_threads              = 4;
