# SensorHouse

A sensor data ingestion and visualization platform built with Kafka, ClickHouse, FastAPI, and Grafana.

## Stack

| Service | Purpose | Port |
|---|---|---|
| Kafka | Message broker for sensor events | 9092 |
| Zookeeper | Kafka coordination | — |
| Redpanda Console | Kafka UI | 8080 |
| ClickHouse | Time-series storage | 8123, 9000 |
| Grafana | Dashboards | 3000 |
| API | REST API (FastAPI) | 8000 |
| Producer | Kafka producer (Python) | — |

## Quick Start

```bash
cp .env.example .env
docker compose up -d --build
```

Wait ~60s for Kafka to be ready, then verify:

```bash
docker compose ps
bash tests/test_m1_infrastructure.sh   # 9 infrastructure checks
bash tests/test_m2_schema.sh           # 9 schema checks (requires ClickHouse init to complete)
bash tests/test_m3_kafka.sh            # 10 Kafka ingestion checks (requires producer to have run)
```

## Testing Milestone 3

Apply the Kafka tables to a running stack, then run the producer and verify:

```bash
# 1. Clear ClickHouse tables and Kafka topic (full reset)
docker exec sensorhouse-clickhouse-1 clickhouse-client --user default --password sensorhouse --query "TRUNCATE TABLE sensors.readings"
docker exec sensorhouse-clickhouse-1 clickhouse-client --user default --password sensorhouse --query "TRUNCATE TABLE sensors.readings_hourly"
docker exec sensorhouse-kafka-1 kafka-topics --bootstrap-server localhost:9092 --delete --topic sensor_readings
docker exec sensorhouse-kafka-1 kafka-topics --bootstrap-server localhost:9092 --create --topic sensor_readings --partitions 3 --replication-factor 1

# 2. Reset Kafka engine table and materialized view
docker exec sensorhouse-clickhouse-1 clickhouse-client --user default --password sensorhouse --query "DROP VIEW IF EXISTS sensors.readings_kafka_mv"
docker exec sensorhouse-clickhouse-1 clickhouse-client --user default --password sensorhouse --query "DROP TABLE IF EXISTS sensors.readings_kafka"
docker exec -i sensorhouse-clickhouse-1 clickhouse-client --user default --password sensorhouse --multiquery < clickhouse/init/06_create_kafka_table.sql
docker exec -i sensorhouse-clickhouse-1 clickhouse-client --user default --password sensorhouse --multiquery < clickhouse/init/07_create_kafka_mv.sql

# 3. Build and run the producer (streams 200k rows, then exits)
docker compose build producer
docker compose run --rm producer

# 4. Run tests
bash tests/test_m3_kafka.sh
```

Watch the pipeline in real time (optional):

```bash
# ClickHouse row count growing
watch -n 2 "docker exec sensorhouse-clickhouse-1 clickhouse-client --user default --password sensorhouse --query 'SELECT count() FROM sensors.readings'"

# Kafka consumer lag (should reach 0 after producer finishes)
docker exec sensorhouse-kafka-1 kafka-consumer-groups --bootstrap-server localhost:9092 --group clickhouse-consumer --describe
```

## Endpoints

- API health: http://localhost:8000/health
- API docs: http://localhost:8000/docs
- Grafana: http://localhost:3000 (admin/sensorhouse)
- Redpanda Console: http://localhost:8080
- ClickHouse: http://localhost:8123/ping

## Milestones

| # | Title | Key deliverable |
|---|---|---|
| 1 | Foundation & Infrastructure | Docker Compose stack, FastAPI `/health`, 9 smoke tests |
| 2 | ClickHouse Schema | `sensors.readings` + `readings_hourly` + materialized view, 2M seed rows, 9 schema tests |
| 3 | Kafka Ingestion Pipeline | Python producer, `readings_kafka` engine table + MV, end-to-end pipeline, 10 ingestion tests |
