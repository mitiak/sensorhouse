# Changelog

## Milestone 2 — ClickHouse Schema (2026-03-13)

- `sensors.readings` table: `ReplacingMergeTree(version)`, partitioned by month, `ORDER BY (sensor_id, timestamp)`, no Nullable columns, `LowCardinality(sensor_type)`, `set(50)` skip index
- `sensors.readings_hourly` table: `AggregatingMergeTree` with `avgState`/`anyState`/`sumState` columns for exact incremental aggregation
- Materialized View `readings_hourly_mv`: incremental pre-aggregation on every INSERT via `-State` combinators
- 2,040,737 rows loaded from Sensor.Community public S3 (June 2019 BMP180 dataset)
- 9 schema tests in `tests/test_m2_schema.sh` (tables, MV, deduplication, rollup)

## Milestone 1 — Foundation & Infrastructure (2026-03-13)

- Docker Compose stack with 6 services: Zookeeper, Kafka, Redpanda Console, ClickHouse, Grafana, API
- FastAPI skeleton with `/health` endpoint
- Kafka producer placeholder (M3 implementation pending)
- ClickHouse configured with `sensors` database and `default` user
- Grafana provisioned with ClickHouse datasource
- 9 smoke tests in `tests/test_m1_infrastructure.sh`
