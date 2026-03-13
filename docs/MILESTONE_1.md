# Milestone 1 — Foundation & Infrastructure

> **Project**: SensorHouse
> **Goal**: Stand up the complete Docker stack, verify all services are healthy, and confirm ClickHouse, Kafka, Grafana, and the API skeleton are all reachable.

---

## What this milestone covers

- Docker Compose with all six services (Zookeeper, Kafka, Redpanda Console, ClickHouse, Grafana, FastAPI)
- Service health checks and dependency ordering
- ClickHouse initial user configuration
- Grafana datasource auto-provisioning skeleton
- FastAPI health-only skeleton
- Environment variable management via `.env`

---

## Project structure after this milestone

```
sensorhouse/
├── docker-compose.yml
├── .env.example
├── .env                          ← copied from .env.example
├── README.md
├── CHANGELOG.md
├── clickhouse/
│   └── config/
│       └── users.xml
├── kafka/
│   └── producer/
│       ├── Dockerfile
│       ├── requirements.txt
│       └── producer.py           ← placeholder
├── api/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── main.py                   ← /health only
└── grafana/
    └── provisioning/
        ├── datasources/
        │   └── clickhouse.yml
        └── dashboards/
            └── dashboards.yml
```

---

## Step-by-step setup

### 1. Initialise the repository

```bash
mkdir sensorhouse && cd sensorhouse
git init
```

### 2. Create `.env.example` and `.env`

```bash
cat > .env.example << 'EOF'
CLICKHOUSE_HOST=clickhouse
CLICKHOUSE_PORT=8123
CLICKHOUSE_USER=default
CLICKHOUSE_PASSWORD=sensorhouse
CLICKHOUSE_DB=sensors

KAFKA_BOOTSTRAP_SERVERS=kafka:9092
KAFKA_TOPIC=sensor-readings

GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=sensorhouse

API_PORT=8000
EOF

cp .env.example .env
```

### 3. Create `docker-compose.yml`

```yaml
version: "3.9"

services:

  zookeeper:
    image: confluentinc/cp-zookeeper:7.6.1
    container_name: sensorhouse-zookeeper
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    healthcheck:
      test: ["CMD", "nc", "-z", "localhost", "2181"]
      interval: 10s
      timeout: 5s
      retries: 5

  kafka:
    image: confluentinc/cp-kafka:7.6.1
    container_name: sensorhouse-kafka
    depends_on:
      zookeeper:
        condition: service_healthy
    ports:
      - "9092:9092"
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092,PLAINTEXT_HOST://localhost:9092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:PLAINTEXT
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"
    healthcheck:
      test: ["CMD", "kafka-broker-api-versions", "--bootstrap-server", "localhost:9092"]
      interval: 15s
      timeout: 10s
      retries: 10

  redpanda-console:
    image: redpandadata/console:v2.6.0
    container_name: sensorhouse-console
    depends_on:
      kafka:
        condition: service_healthy
    ports:
      - "8080:8080"
    environment:
      KAFKA_BROKERS: kafka:9092

  clickhouse:
    image: clickhouse/clickhouse-server:24.3
    container_name: sensorhouse-clickhouse
    depends_on:
      kafka:
        condition: service_healthy
    ports:
      - "8123:8123"
      - "9000:9000"
    environment:
      CLICKHOUSE_DB: ${CLICKHOUSE_DB}
      CLICKHOUSE_USER: ${CLICKHOUSE_USER}
      CLICKHOUSE_PASSWORD: ${CLICKHOUSE_PASSWORD}
    volumes:
      - clickhouse_data:/var/lib/clickhouse
      - ./clickhouse/config/users.xml:/etc/clickhouse-server/users.d/users.xml:ro
      - ./clickhouse/init:/docker-entrypoint-initdb.d:ro
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8123/ping"]
      interval: 10s
      timeout: 5s
      retries: 10

  grafana:
    image: grafana/grafana:10.4.2
    container_name: sensorhouse-grafana
    depends_on:
      clickhouse:
        condition: service_healthy
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_USER: ${GRAFANA_ADMIN_USER}
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD}
      GF_INSTALL_PLUGINS: grafana-clickhouse-datasource
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro

  api:
    build: ./api
    container_name: sensorhouse-api
    depends_on:
      clickhouse:
        condition: service_healthy
    ports:
      - "${API_PORT}:8000"
    env_file: .env
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 15s
      timeout: 5s
      retries: 5

volumes:
  clickhouse_data:
  grafana_data:
```

### 4. Create ClickHouse user config

```bash
mkdir -p clickhouse/config clickhouse/init
```

**`clickhouse/config/users.xml`**
```xml
<clickhouse>
  <users>
    <default>
      <password>sensorhouse</password>
      <networks>
        <ip>::/0</ip>
      </networks>
      <profile>default</profile>
      <quota>default</quota>
      <access_management>1</access_management>
    </default>
  </users>
</clickhouse>
```

### 5. Create the FastAPI skeleton

**`api/requirements.txt`**
```
fastapi==0.111.0
uvicorn[standard]==0.29.0
clickhouse-connect==0.7.16
python-dotenv==1.0.1
```

**`api/main.py`**
```python
from fastapi import FastAPI

app = FastAPI(title="SensorHouse API", version="0.1.0")

@app.get("/health")
def health():
    return {"status": "ok", "service": "sensorhouse-api"}
```

**`api/Dockerfile`**
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### 6. Create Grafana provisioning

**`grafana/provisioning/datasources/clickhouse.yml`**
```yaml
apiVersion: 1
datasources:
  - name: ClickHouse
    type: grafana-clickhouse-datasource
    uid: clickhouse-sensors
    isDefault: true
    jsonData:
      host: clickhouse
      port: 8123
      username: default
      defaultDatabase: sensors
    secureJsonData:
      password: sensorhouse
```

**`grafana/provisioning/dashboards/dashboards.yml`**
```yaml
apiVersion: 1
providers:
  - name: SensorHouse
    folder: SensorHouse
    type: file
    options:
      path: /etc/grafana/provisioning/dashboards
```

---

## How to run this milestone

```bash
# Start all services (builds the API image first)
docker compose up -d --build

# Follow logs during startup (~60s for Kafka to be ready)
docker compose logs -f

# Check all container statuses
docker compose ps
```

Expected `docker compose ps` output (all healthy):

```
NAME                        STATUS
sensorhouse-zookeeper       running (healthy)
sensorhouse-kafka           running (healthy)
sensorhouse-console         running
sensorhouse-clickhouse      running (healthy)
sensorhouse-grafana         running
sensorhouse-api             running (healthy)
```

---

## Manual verification commands

```bash
# ClickHouse HTTP ping
curl http://localhost:8123/ping
# → Ok.

# ClickHouse query via HTTP
curl "http://localhost:8123/?user=default&password=sensorhouse&query=SELECT+version()"
# → 24.3.x.x

# ClickHouse interactive shell
docker exec -it sensorhouse-clickhouse \
  clickhouse-client --user default --password sensorhouse
# Inside shell:
#   SELECT version();
#   SHOW DATABASES;
#   EXIT;

# Kafka: list topics (empty at this stage)
docker exec sensorhouse-kafka \
  kafka-topics --bootstrap-server localhost:9092 --list

# Redpanda Console web UI
open http://localhost:8080

# Grafana web UI (admin / sensorhouse)
open http://localhost:3000

# API health
curl http://localhost:8000/health
# → {"status":"ok","service":"sensorhouse-api"}

# API docs
open http://localhost:8000/docs
```

---

## Tests

Save as `tests/test_m1_infrastructure.sh`:

```bash
#!/usr/bin/env bash
# SensorHouse – Milestone 1 smoke tests
set -euo pipefail
PASS=0; FAIL=0

check() {
  local desc="$1" cmd="$2" expected="$3"
  local result
  result=$(eval "$cmd" 2>/dev/null | tr -d '[:space:]') || result=""
  if echo "$result" | grep -q "$expected"; then
    echo "  PASS  $desc"; PASS=$((PASS+1))
  else
    echo "  FAIL  $desc  (got: '${result:0:80}')"; FAIL=$((FAIL+1))
  fi
}

echo ""
echo "=== SensorHouse · Milestone 1: Infrastructure ==="
echo ""

check "ClickHouse HTTP ping" \
  "curl -s http://localhost:8123/ping" "Ok"

check "ClickHouse SELECT 1" \
  "curl -s 'http://localhost:8123/?user=default&password=sensorhouse&query=SELECT+1'" "1"

check "ClickHouse version returned" \
  "curl -s 'http://localhost:8123/?user=default&password=sensorhouse&query=SELECT+version()'" "24"

check "Database 'sensors' exists" \
  "curl -s 'http://localhost:8123/?user=default&password=sensorhouse&query=SHOW+DATABASES' | grep sensors" "sensors"

check "Kafka broker API responds" \
  "docker exec sensorhouse-kafka kafka-broker-api-versions --bootstrap-server localhost:9092 2>&1 | head -5" "Supported"

check "Redpanda Console UI returns 200" \
  "curl -s -o /dev/null -w '%{http_code}' http://localhost:8080" "200"

check "Grafana login page returns 200" \
  "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/login" "200"

check "API /health returns ok" \
  "curl -s http://localhost:8000/health" "ok"

check "API /docs returns 200" \
  "curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/docs" "200"

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""
[ "$FAIL" -eq 0 ] && echo "✓ Milestone 1 COMPLETE" || { echo "✗ Fix failures before proceeding"; exit 1; }
```

Run it:

```bash
chmod +x tests/test_m1_infrastructure.sh
bash tests/test_m1_infrastructure.sh
```

### Expected output

```
=== SensorHouse · Milestone 1: Infrastructure ===

  PASS  ClickHouse HTTP ping
  PASS  ClickHouse SELECT 1
  PASS  ClickHouse version returned
  PASS  Database 'sensors' exists
  PASS  Kafka broker API responds
  PASS  Redpanda Console UI returns 200
  PASS  Grafana login page returns 200
  PASS  API /health returns ok
  PASS  API /docs returns 200

Results: 9 passed, 0 failed

✓ Milestone 1 COMPLETE
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| ClickHouse container unhealthy | Port 9000 conflict | Change `"9000:9000"` to `"9900:9000"` in compose |
| Kafka loops and restarts | Zookeeper not ready | Wait 30s, then `docker compose restart kafka` |
| Grafana plugin missing | Slow first pull | Check `docker compose logs grafana` — plugin install takes ~60s |
| API exits immediately | `.env` missing | Run `cp .env.example .env` |
| `sensors` DB not listed | Init scripts not mounted | Confirm `./clickhouse/init` exists; restart clickhouse |

---

## Definition of done

- [ ] `docker compose ps` shows all 6 services running/healthy
- [ ] `curl http://localhost:8123/ping` → `Ok.`
- [ ] ClickHouse shell works: `SELECT version()` returns `24.x`
- [ ] Redpanda Console UI loads at `http://localhost:8080`
- [ ] Grafana loads at `http://localhost:3000`
- [ ] `curl http://localhost:8000/health` → `{"status":"ok",...}`
- [ ] All 9 automated tests pass
