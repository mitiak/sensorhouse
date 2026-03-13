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

## Quick Start[MILESTONE_2.md](docs/MILESTONE_2.md)
[MILESTONE_1.md](docs/MILESTONE_1.md)[MILESTONE_2.md](docs/MILESTONE_2.md)
```bash
cp .env.example .env
docker compose up -d --build
```

Wait ~60s for Kafka to be ready, then verify:

```bash
docker compose ps
bash tests/test_m1_infrastructure.sh
```

## Endpoints

- API health: http://localhost:8000/health
- API docs: http://localhost:8000/docs
- Grafana: http://localhost:3000 (admin/sensorhouse)
- Redpanda Console: http://localhost:8080
- ClickHouse: http://localhost:8123/ping
