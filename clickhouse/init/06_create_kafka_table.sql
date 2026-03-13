-- The Kafka engine table is a "connector" — it does NOT store data.
-- It reads from the Kafka topic and exposes rows for the Materialized View.
CREATE TABLE IF NOT EXISTS sensors.readings_kafka
(
    sensor_id          UInt32,
    sensor_type        String,
    location           UInt32,
    lat                Nullable(Float32),
    lon                Nullable(Float32),
    ts                 String,              -- parsed in the MV SELECT (renamed: 'timestamp' is a reserved type alias)
    P1                 Nullable(Float32),
    P2                 Nullable(Float32),
    P0                 Nullable(Float32),
    pressure           Nullable(Float32),
    altitude           Nullable(Float32),
    pressure_sealevel  Nullable(Float32),
    temperature        Nullable(Float32),
    humidity           Nullable(Float32),
    version            UInt64
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list          = 'kafka:29092',
    kafka_topic_list           = 'sensor_readings',
    kafka_group_name           = 'clickhouse-consumer',
    kafka_format               = 'JSONEachRow',
    kafka_num_consumers        = 2,
    kafka_skip_broken_messages = 100;
