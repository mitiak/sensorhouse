# Changelog

## Milestone 4 — REST API & Grafana Dashboards (2026-03-13)

- `api/db.py` — lazy-initialized `clickhouse-connect` singleton client; reads host/port/credentials from env with sensible defaults
- `api/main.py` — full FastAPI implementation with 7 endpoints: `/health`, `/health/db`, `/api/v1/daily-counts`, `/api/v1/hottest-days`, `/api/v1/sensors/{id}/history`, `/api/v1/top-pm25`, `/api/v1/geo-heatmap`; metric allowlists return 400 for invalid input; hourly rollup endpoints use correct `-Merge` combinators (`avgMerge`, `anyMerge`, `sumMerge`) against `AggregatingMergeTree` columns
- OpenAPI docs auto-generated at `/docs` (Swagger UI)
- `clickhouse/init/08_add_ttl.sql` — `ALTER TABLE sensors.readings MODIFY TTL date + INTERVAL 5 YEAR`; auto-expires data older than 5 years during background merges
- Four Grafana dashboards provisioned from JSON in `grafana/provisioning/dashboards/`: **Overview** (total rows, distinct sensors, daily time series), **PM2.5 Air Quality** (hourly avg trend + top-10 bar gauge), **Hot & Humid Days** (bar chart of extreme weather events), **Geo Heatmap** (2° lat/lon grid table with temperature/pressure)
- 16 tests in `tests/test_m4_api.sh` (API endpoints, 400 validation, OpenAPI docs, TTL, query_log, Grafana UI, datasource)

## Milestone 3 — Kafka Ingestion Pipeline (2026-03-13)

- `kafka/producer/producer.py` — Python producer streams the Sensor.Community BMP180 S3 dataset into the `sensor-readings` Kafka topic; supports `REPLAY_SPEED`, `ROW_LIMIT`, and `SENSOR_TYPE_FILTER` env vars; publishes JSON with `acks=all`, gzip compression, and `sensor_id` as the message key
- `sensors.readings_kafka` — ClickHouse Kafka engine table (`06_create_kafka_table.sql`): 2-consumer `clickhouse-consumer` group, `JSONEachRow` format, skips up to 100 broken messages
- `sensors.readings_kafka_mv` — Materialized View (`07_create_kafka_mv.sql`) normalises Nullables via `coalesce`, parses timestamp strings with `parseDateTimeBestEffort`, and filters out rows with empty `sensor_type` or invalid timestamps before writing to `sensors.readings`
- `producer` Docker service added to `docker-compose.yml`; default `ROW_LIMIT=200000`, replays at full speed (`REPLAY_SPEED=0`)
- Kafka topic `sensor-readings` auto-created with 3 partitions on first producer connect
- End-to-end MV chain verified: Kafka rows flow through `readings_kafka_mv` into `sensors.readings`, then trigger the existing `readings_hourly_mv` aggregation
- 10 tests in `tests/test_m3_kafka.sh` (topic existence, partition count, Kafka engine table, Kafka MV, row counts, timestamp validity, null-filter, coalesce, hourly aggregation)

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
