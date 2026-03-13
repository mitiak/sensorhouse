# Changelog

## Milestone 1 — Foundation & Infrastructure (2026-03-13)

- Docker Compose stack with 6 services: Zookeeper, Kafka, Redpanda Console, ClickHouse, Grafana, API
- FastAPI skeleton with `/health` endpoint
- Kafka producer placeholder (M3 implementation pending)
- ClickHouse configured with `sensors` database and `default` user
- Grafana provisioned with ClickHouse datasource
- 9 smoke tests in `tests/test_m1_infrastructure.sh`
