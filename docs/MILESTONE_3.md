# Milestone 3 — Kafka Ingestion Pipeline

> **Project**: SensorHouse
> **Prerequisite**: Milestone 2 complete — schema exists, sample data loaded.
> **Goal**: Build a real-time ingestion pipeline: a Python producer replays sensor readings into Kafka, and ClickHouse consumes them automatically via the Kafka engine + Materialized View pattern.

---

## What this milestone covers

- Kafka topic creation with correct partition count
- Python producer that replays the S3 dataset as a real-time event stream
- ClickHouse Kafka engine table (`sensors.readings_kafka`)
- Materialized View routing Kafka → `sensors.readings`
- Back-pressure handling and error recovery
- Observability: consumer lag, throughput metrics
- Redpanda Console topic inspection

---

## Architecture for this milestone

```
S3 CSV file
    ↓
Python producer (Docker)
    ↓  JSON messages
Kafka topic: sensor-readings  (3 partitions)
    ↓
ClickHouse Kafka engine table  ← polls topic
    ↓  Materialized View
sensors.readings  (ReplacingMergeTree)
    ↓
sensors.readings_hourly  (via existing MV)
```

---

## Project structure additions

```
sensorhouse/
└── kafka/
    └── producer/
        ├── Dockerfile
        ├── requirements.txt
        └── producer.py
```

And two new SQL files:

```
clickhouse/
└── init/
    ├── 06_create_kafka_table.sql
    └── 07_create_kafka_mv.sql
```

---

## Step-by-step setup

### 1. Create the Kafka topic

The topic is created automatically by Kafka when the first producer connects (because `KAFKA_AUTO_CREATE_TOPICS_ENABLE=true`), but creating it explicitly gives us control over partition count and replication:

```bash
docker exec sensorhouse-kafka \
  kafka-topics \
    --bootstrap-server localhost:9092 \
    --create \
    --topic sensor-readings \
    --partitions 3 \
    --replication-factor 1 \
    --if-not-exists
```

### 2. Create `kafka/producer/requirements.txt`

```
kafka-python==2.0.2
requests==2.31.0
boto3==1.34.0
python-dotenv==1.0.1
```

### 3. Create `kafka/producer/producer.py`

```python
"""
SensorHouse Kafka Producer
Streams sensor readings from the S3 CSV dataset into Kafka as JSON events.
Supports: replay speed multiplier, sensor_type filter, row limit.
"""
import csv
import gzip
import io
import json
import logging
import os
import time
import urllib.request
from datetime import datetime
from dotenv import load_dotenv
from kafka import KafkaProducer
from kafka.errors import KafkaError

load_dotenv()
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("producer")

KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
TOPIC           = os.getenv("KAFKA_TOPIC", "sensor-readings")
REPLAY_SPEED    = float(os.getenv("REPLAY_SPEED", "0"))   # 0 = as fast as possible
ROW_LIMIT       = int(os.getenv("ROW_LIMIT", "0"))        # 0 = no limit
SENSOR_TYPE     = os.getenv("SENSOR_TYPE_FILTER", "")     # empty = all types
BATCH_SIZE      = int(os.getenv("BATCH_SIZE", "500"))

# One month of BMP180 data — small enough for a workshop
S3_URL = (
    "https://clickhouse-public-datasets.s3.eu-central-1.amazonaws.com"
    "/sensors/monthly/2019-06_bmp180.csv.zst"
)


def make_producer() -> KafkaProducer:
    return KafkaProducer(
        bootstrap_servers=KAFKA_BOOTSTRAP,
        value_serializer=lambda v: json.dumps(v).encode("utf-8"),
        acks="all",
        retries=5,
        batch_size=32768,
        linger_ms=20,
        compression_type="gzip",
    )


def stream_csv(url: str):
    """Download and decompress a .csv.zst file, yield rows as dicts."""
    import zstandard as zstd  # lazily imported so the container can start without it

    log.info("Downloading dataset from S3 …")
    with urllib.request.urlopen(url) as resp:
        raw = resp.read()

    log.info("Decompressing …")
    dctx = zstd.ZstdDecompressor()
    text = dctx.decompress(raw).decode("utf-8")
    reader = csv.DictReader(io.StringIO(text), delimiter=";")
    yield from reader


def send(producer: KafkaProducer, row: dict, version: int) -> None:
    """Normalise one CSV row and publish to Kafka."""
    def safe_float(v):
        try:
            return float(v) if v not in ("", "nan", "NULL") else None
        except (ValueError, TypeError):
            return None

    msg = {
        "sensor_id":   int(row.get("sensor_id", 0) or 0),
        "sensor_type": row.get("sensor_type", ""),
        "location":    int(row.get("location", 0) or 0),
        "lat":         safe_float(row.get("lat")),
        "lon":         safe_float(row.get("lon")),
        "timestamp":   row.get("timestamp", ""),
        "P1":          safe_float(row.get("P1")),
        "P2":          safe_float(row.get("P2")),
        "P0":          safe_float(row.get("P0")),
        "pressure":    safe_float(row.get("pressure")),
        "altitude":    safe_float(row.get("altitude")),
        "temperature": safe_float(row.get("temperature")),
        "humidity":    safe_float(row.get("humidity")),
        "version":     version,
    }
    producer.send(TOPIC, value=msg, key=str(msg["sensor_id"]).encode())


def main():
    log.info("Connecting to Kafka at %s …", KAFKA_BOOTSTRAP)
    producer = make_producer()
    log.info("Connected. Producing to topic '%s'", TOPIC)

    sent = 0
    errors = 0
    start = time.time()

    for row in stream_csv(S3_URL):
        if SENSOR_TYPE and row.get("sensor_type") != SENSOR_TYPE:
            continue
        try:
            send(producer, row, version=int(time.time() * 1000))
            sent += 1
        except KafkaError as e:
            log.warning("Send error: %s", e)
            errors += 1

        if sent % BATCH_SIZE == 0:
            producer.flush()
            elapsed = time.time() - start
            log.info("Sent %d rows | errors=%d | %.0f rows/s", sent, errors, sent / elapsed)

        if REPLAY_SPEED > 0:
            time.sleep(1.0 / REPLAY_SPEED)

        if ROW_LIMIT and sent >= ROW_LIMIT:
            log.info("Row limit %d reached. Stopping.", ROW_LIMIT)
            break

    producer.flush()
    elapsed = time.time() - start
    log.info("Done. Sent %d rows in %.1fs (%.0f rows/s). Errors: %d",
             sent, elapsed, sent / elapsed, errors)


if __name__ == "__main__":
    main()
```

### 4. Update `requirements.txt` to include zstandard

```
kafka-python==2.0.2
zstandard==0.22.0
python-dotenv==1.0.1
```

### 5. Create `kafka/producer/Dockerfile`

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python", "producer.py"]
```

### 6. Add producer to `docker-compose.yml`

Add this service under `services:`:

```yaml
  producer:
    build: ./kafka/producer
    container_name: sensorhouse-producer
    depends_on:
      kafka:
        condition: service_healthy
    env_file: .env
    environment:
      KAFKA_BOOTSTRAP_SERVERS: kafka:9092
      REPLAY_SPEED: "0"       # 0 = max speed
      ROW_LIMIT: "200000"     # limit for workshop; remove for full load
    restart: "no"             # run once and exit
```

### 7. Create ClickHouse Kafka engine table

**`clickhouse/init/06_create_kafka_table.sql`**

```sql
-- The Kafka engine table is a "connector" — it does NOT store data.
-- It reads from the Kafka topic and exposes rows for the Materialized View.
CREATE TABLE IF NOT EXISTS sensors.readings_kafka
(
    sensor_id          UInt32,
    sensor_type        String,
    location           UInt32,
    lat                Nullable(Float32),
    lon                Nullable(Float32),
    timestamp          String,   -- parsed in the MV SELECT
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
    kafka_broker_list       = 'kafka:9092',
    kafka_topic_list        = 'sensor-readings',
    kafka_group_name        = 'clickhouse-consumer',
    kafka_format            = 'JSONEachRow',
    kafka_num_consumers     = 2,
    kafka_skip_broken_messages = 100;
```

### 8. Create the Kafka → readings Materialized View

**`clickhouse/init/07_create_kafka_mv.sql`**

```sql
-- Fires for every batch ClickHouse polls from Kafka.
-- Normalises nulls, parses timestamp string, and writes to sensors.readings.
CREATE MATERIALIZED VIEW IF NOT EXISTS sensors.readings_kafka_mv
TO sensors.readings
AS
SELECT
    sensor_id,
    sensor_type,
    location,
    coalesce(lat, 0.0)               AS lat,
    coalesce(lon, 0.0)               AS lon,
    parseDateTimeBestEffort(timestamp) AS timestamp,
    coalesce(P1, 0.0)                AS P1,
    coalesce(P2, 0.0)                AS P2,
    coalesce(P0, 0.0)                AS P0,
    0.0                              AS durP1,
    0.0                              AS ratioP1,
    0.0                              AS durP2,
    0.0                              AS ratioP2,
    coalesce(pressure, 0.0)          AS pressure,
    coalesce(altitude, 0.0)          AS altitude,
    coalesce(pressure_sealevel, 0.0) AS pressure_sealevel,
    coalesce(temperature, 0.0)       AS temperature,
    coalesce(humidity, 0.0)          AS humidity,
    version
FROM sensors.readings_kafka
WHERE sensor_id > 0
  AND length(sensor_type) > 0
  AND parseDateTimeBestEffort(timestamp) > toDateTime('2010-01-01');
```

---

## How to run this milestone

### Apply new SQL files to running ClickHouse

```bash
# Apply Kafka table and MV (if stack is already up from M2)
for f in clickhouse/init/06_*.sql clickhouse/init/07_*.sql; do
  echo "Applying $f ..."
  docker exec -i sensorhouse-clickhouse \
    clickhouse-client --user default --password sensorhouse \
    --multiquery < "$f"
done
```

### Start the producer

```bash
# Option A: via Docker Compose (runs once, streams 200k rows then exits)
docker compose run --rm producer

# Option B: run directly on the host (install deps first)
pip install kafka-python zstandard python-dotenv
KAFKA_BOOTSTRAP_SERVERS=localhost:9092 ROW_LIMIT=50000 python kafka/producer/producer.py
```

### Watch the pipeline in real time

```bash
# Terminal 1: producer logs
docker compose logs -f producer

# Terminal 2: ClickHouse row count growing
watch -n 2 "docker exec sensorhouse-clickhouse \
  clickhouse-client --user default --password sensorhouse \
  --query 'SELECT count() FROM sensors.readings'"

# Terminal 3: Kafka consumer lag
docker exec sensorhouse-kafka \
  kafka-consumer-groups \
    --bootstrap-server localhost:9092 \
    --group clickhouse-consumer \
    --describe
```

---

## Manual verification commands

```bash
docker exec -it sensorhouse-clickhouse \
  clickhouse-client --user default --password sensorhouse --database sensors
```

Inside the ClickHouse shell:

```sql
-- Row count after producer run
SELECT count() FROM sensors.readings;

-- Latest ingested rows
SELECT sensor_id, sensor_type, timestamp, temperature
FROM sensors.readings
ORDER BY timestamp DESC
LIMIT 10;

-- Throughput: rows by minute
SELECT
    toStartOfMinute(timestamp) AS minute,
    count()                    AS rows
FROM sensors.readings
GROUP BY minute
ORDER BY minute DESC
LIMIT 20;

-- Partition distribution (data spread across months)
SELECT partition, count() AS rows, formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE database = 'sensors' AND table = 'readings' AND active = 1
GROUP BY partition;

-- Kafka consumer lag (0 = fully caught up)
SELECT * FROM system.kafka_consumers
WHERE database = 'sensors';

-- Hourly table populated via MV chain
SELECT count() FROM sensors.readings_hourly;
SELECT hour, avg_temp, avg_P2, sample_count
FROM sensors.readings_hourly
ORDER BY hour DESC
LIMIT 10;
```

---

## Redpanda Console inspection

Open `http://localhost:8080` and confirm:

1. Topic `sensor-readings` exists with 3 partitions
2. Each partition shows message offset > 0
3. Consumer group `clickhouse-consumer` shows near-zero lag after producer finishes

---

## Tests

Save as `tests/test_m3_kafka.sh`:

```bash
#!/usr/bin/env bash
# SensorHouse – Milestone 3: Kafka ingestion tests
set -euo pipefail
PASS=0; FAIL=0

CH="docker exec sensorhouse-clickhouse clickhouse-client \
    --user default --password sensorhouse --database sensors \
    --format TabSeparated --query"

check() {
  local desc="$1" cmd="$2" expected="$3"
  local result
  result=$(eval "$cmd" 2>/dev/null | tr -d '[:space:]') || result=""
  if echo "$result" | grep -q "$expected"; then
    echo "  PASS  $desc"; PASS=$((PASS+1))
  else
    echo "  FAIL  $desc  (got: '${result:0:120}')"; FAIL=$((FAIL+1))
  fi
}

echo ""
echo "=== SensorHouse · Milestone 3: Kafka Ingestion ==="
echo ""

check "Kafka topic 'sensor-readings' exists" \
  "docker exec sensorhouse-kafka kafka-topics --bootstrap-server localhost:9092 --list" \
  "sensor-readings"

check "Topic has 3 partitions" \
  "docker exec sensorhouse-kafka kafka-topics --bootstrap-server localhost:9092 --describe --topic sensor-readings | grep -c PartitionCount" \
  "1"

check "Kafka engine table exists" \
  "$CH 'EXISTS TABLE sensors.readings_kafka'" "1"

check "Kafka MV exists" \
  "$CH \"SELECT count() FROM system.tables WHERE database='sensors' AND name='readings_kafka_mv'\"" "1"

check "readings table has > 1000 rows (pipeline ran)" \
  "$CH 'SELECT count() > 1000 FROM sensors.readings'" "1"

check "readings_hourly populated (MV chain works)" \
  "$CH 'SELECT count() > 0 FROM sensors.readings_hourly'" "1"

check "Latest timestamp is recent (not epoch 0)" \
  "$CH 'SELECT max(timestamp) > toDateTime(1000000000) FROM sensors.readings'" "1"

check "No NULL sensor_type in readings (Kafka MV filter works)" \
  "$CH \"SELECT count() FROM sensors.readings WHERE length(sensor_type)=0\"" "0"

check "Temperature values non-zero (coalesce worked)" \
  "$CH 'SELECT count() > 0 FROM sensors.readings WHERE temperature > 0'" "1"

check "Hourly MV has avg_temp populated" \
  "$CH 'SELECT count() > 0 FROM sensors.readings_hourly WHERE avg_temp > 0'" "1"

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""
[ "$FAIL" -eq 0 ] && echo "✓ Milestone 3 COMPLETE" || { echo "✗ Fix failures before proceeding"; exit 1; }
```

Run it:

```bash
chmod +x tests/test_m3_kafka.sh
bash tests/test_m3_kafka.sh
```

### Expected output

```
=== SensorHouse · Milestone 3: Kafka Ingestion ===

  PASS  Kafka topic 'sensor-readings' exists
  PASS  Topic has 3 partitions
  PASS  Kafka engine table exists
  PASS  Kafka MV exists
  PASS  readings table has > 1000 rows (pipeline ran)
  PASS  readings_hourly populated (MV chain works)
  PASS  Latest timestamp is recent (not epoch 0)
  PASS  No NULL sensor_type in readings (Kafka MV filter works)
  PASS  Temperature values non-zero (coalesce worked)
  PASS  Hourly MV has avg_temp populated

Results: 10 passed, 0 failed

✓ Milestone 3 COMPLETE
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Producer exits with `NoBrokersAvailable` | Kafka not ready | Wait for Kafka healthcheck, then re-run producer |
| `readings` count stays at 0 | Kafka MV not attached | Check `SELECT * FROM system.kafka_consumers` in CH |
| Consumer lag never reaches 0 | ClickHouse is slow | Increase `kafka_num_consumers` to 4 |
| `parseDateTimeBestEffort` errors | Timestamp format varies | Add `input_format_allow_errors_ratio=0.5` to Kafka table settings |
| Zstandard decompression error | Library not installed | Rebuild producer image: `docker compose build producer` |

---

## Definition of done

- [ ] Kafka topic `sensor-readings` exists with 3 partitions
- [ ] Producer streams at least 100k rows without crashing
- [ ] `SELECT count() FROM sensors.readings` grows in real time while producer runs
- [ ] Consumer lag reaches 0 after producer finishes
- [ ] `sensors.readings_hourly` is populated (MV chain works end-to-end)
- [ ] Redpanda Console shows messages in all 3 partitions
- [ ] All 10 automated tests pass
