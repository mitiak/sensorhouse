# Milestone 2 — Schema, MergeTree & Deduplication

> **Project**: SensorHouse
> **Prerequisite**: Milestone 1 complete — all containers running and healthy.
> **Goal**: Design and create the production ClickHouse schema using `ReplacingMergeTree` for deduplication, apply ClickHouse best practices (partition key, primary key ordering, typed columns, materialized columns), and demonstrate deduplication behaviour end-to-end.

---

## What this milestone covers

- `sensors` main table using `ReplacingMergeTree`
- Correct `ORDER BY` and `PARTITION BY` design
- Typed columns: `Enum`, `Float32`, `LowCardinality`, `MATERIALIZED`
- `sensors_hourly` pre-aggregation table
- Materialized View connecting `sensors` → `sensors_hourly`
- Deduplication demonstration with `FINAL` and `OPTIMIZE`
- Data skipping index on `sensor_type`
- Initial seed load from S3 (small sample)
- Init SQL scripts auto-run by ClickHouse on startup

---

## Project structure additions

```
sensorhouse/
└── clickhouse/
    └── init/
        ├── 01_create_database.sql
        ├── 02_create_sensors_table.sql
        ├── 03_create_hourly_table.sql
        ├── 04_create_hourly_mv.sql
        └── 05_load_sample.sql
```

---

## Schema design decisions

### Why `ReplacingMergeTree`?

Sensor networks emit duplicate readings — a sensor may publish the same measurement multiple times due to retries or network issues. `ReplacingMergeTree` keeps only the row with the highest `version` value (a `UInt64` Unix timestamp) for each unique key during background merges.

### Why `ORDER BY (sensor_id, timestamp)`?

ClickHouse stores data sorted by the `ORDER BY` key, which also serves as the primary index. Putting `sensor_id` first means all readings for one sensor are physically adjacent — range scans by sensor or time for a sensor are fast. The dataset's most common query patterns are "give me sensor X over time" and "aggregate over a time range for all sensors", both of which benefit from this ordering.

### Why `PARTITION BY toYYYYMM(timestamp)`?

Monthly partitions allow ClickHouse to skip entire months when a query has a time-range filter, and they keep individual partition sizes manageable (~tens of millions of rows per month). Avoid daily partitions — too many parts.

---

## SQL files

### `clickhouse/init/01_create_database.sql`

```sql
CREATE DATABASE IF NOT EXISTS sensors;
```

### `clickhouse/init/02_create_sensors_table.sql`

```sql
CREATE TABLE IF NOT EXISTS sensors.readings
(
    sensor_id          UInt32,
    sensor_type        LowCardinality(String),
    location           UInt32,
    lat                Float32,
    lon                Float32,
    timestamp          DateTime,

    -- Particulate matter (dust sensors)
    P1                 Float32,   -- PM10  µg/m³
    P2                 Float32,   -- PM2.5 µg/m³
    P0                 Float32,   -- PM1   µg/m³
    durP1              Float32,
    ratioP1            Float32,
    durP2              Float32,
    ratioP2            Float32,

    -- Atmospheric sensors
    pressure           Float32,   -- Pa
    altitude           Float32,   -- m
    pressure_sealevel  Float32,   -- Pa
    temperature        Float32,   -- °C
    humidity           Float32,   -- %

    -- Deduplication version (higher = more recent)
    version            UInt64     DEFAULT toUnixTimestamp(now()),

    -- Materialized column: no storage cost, free for partitioning
    date               Date       MATERIALIZED toDate(timestamp)
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (sensor_id, timestamp)
SETTINGS index_granularity = 8192;

-- Data skipping index: avoids scanning all parts when filtering by sensor_type
ALTER TABLE sensors.readings
    ADD INDEX IF NOT EXISTS idx_sensor_type (sensor_type) TYPE set(50) GRANULARITY 4;
```

### `clickhouse/init/03_create_hourly_table.sql`

```sql
-- Pre-aggregated hourly averages — queried by Grafana for performance
CREATE TABLE IF NOT EXISTS sensors.readings_hourly
(
    sensor_id     UInt32,
    sensor_type   LowCardinality(String),
    hour          DateTime,
    avg_temp      Float32,
    avg_humidity  Float32,
    avg_pressure  Float32,
    avg_P1        Float32,
    avg_P2        Float32,
    lat           Float32,
    lon           Float32,
    sample_count  UInt32
)
ENGINE = ReplacingMergeTree()
PARTITION BY toYYYYMM(hour)
ORDER BY (sensor_id, hour)
SETTINGS index_granularity = 8192;
```

### `clickhouse/init/04_create_hourly_mv.sql`

```sql
-- Materialized View: fires on every INSERT into sensors.readings
-- and populates readings_hourly automatically
CREATE MATERIALIZED VIEW IF NOT EXISTS sensors.readings_hourly_mv
TO sensors.readings_hourly
AS
SELECT
    sensor_id,
    sensor_type,
    toStartOfHour(timestamp)    AS hour,
    avgIf(temperature, temperature != 0)  AS avg_temp,
    avgIf(humidity,    humidity    != 0)  AS avg_humidity,
    avgIf(pressure,    pressure    != 0)  AS avg_pressure,
    avgIf(P1, P1 != 0)                   AS avg_P1,
    avgIf(P2, P2 != 0)                   AS avg_P2,
    any(lat)                              AS lat,
    any(lon)                              AS lon,
    count()                               AS sample_count
FROM sensors.readings
GROUP BY sensor_id, sensor_type, hour;
```

### `clickhouse/init/05_load_sample.sql`

```sql
-- Load one month of BMP180 data (~few million rows) from public S3
-- Uses s3() table function — no credentials needed (public bucket)
INSERT INTO sensors.readings
    (sensor_id, sensor_type, location, lat, lon, timestamp,
     pressure, temperature, version)
SELECT
    sensor_id,
    sensor_type,
    location,
    lat,
    lon,
    timestamp,
    pressure,
    temperature,
    toUnixTimestamp(now()) AS version
FROM s3(
    'https://clickhouse-public-datasets.s3.eu-central-1.amazonaws.com/sensors/monthly/2019-06_bmp180.csv.zst',
    'CSVWithNames'
)
SETTINGS
    format_csv_delimiter = ';',
    input_format_allow_errors_ratio = 0.5,
    input_format_allow_errors_num = 1000,
    date_time_input_format = 'best_effort';
```

> **Note**: The full dataset is 20B+ rows. This init script loads only one monthly file (~1–5M rows) for workshop purposes. Expand in Milestone 3 via the Kafka producer.

---

## How to run this milestone

The SQL files in `clickhouse/init/` run automatically when the ClickHouse container starts (because the directory is mounted to `/docker-entrypoint-initdb.d/`). Files are executed in alphabetical order.

### First-time setup (clean start)

```bash
# Destroy existing volumes (clears any previous DB state)
docker compose down -v

# Restart — init scripts run automatically during ClickHouse startup
docker compose up -d --build

# Watch ClickHouse init logs
docker compose logs -f clickhouse
```

You should see lines like:
```
clickhouse-clickhouse | Executing /docker-entrypoint-initdb.d/01_create_database.sql
clickhouse-clickhouse | Executing /docker-entrypoint-initdb.d/02_create_sensors_table.sql
...
```

### Apply schema to a running stack (no volume wipe)

```bash
# Run each SQL file manually via clickhouse-client
for f in clickhouse/init/*.sql; do
  echo "Running $f..."
  docker exec -i sensorhouse-clickhouse \
    clickhouse-client --user default --password sensorhouse \
    --multiquery < "$f"
done
```

### Trigger sample data load manually

```bash
docker exec -it sensorhouse-clickhouse \
  clickhouse-client --user default --password sensorhouse \
  --query "$(cat clickhouse/init/05_load_sample.sql)"
```

---

## Manual verification commands

```bash
# Open ClickHouse shell
docker exec -it sensorhouse-clickhouse \
  clickhouse-client --user default --password sensorhouse --database sensors

# Inside the shell — run these one by one:

-- Confirm tables exist
SHOW TABLES IN sensors;
-- Expected: readings, readings_hourly, readings_hourly_mv

-- Count rows loaded
SELECT count() FROM sensors.readings;
-- Expected: > 0 (after sample load completes)

-- Preview data
SELECT sensor_id, sensor_type, timestamp, temperature, humidity
FROM sensors.readings
LIMIT 5;

-- Check partition distribution
SELECT partition, count() AS rows, formatReadableSize(sum(bytes_on_disk)) AS size
FROM system.parts
WHERE database = 'sensors' AND table = 'readings' AND active = 1
GROUP BY partition
ORDER BY partition;

-- Confirm materialized view populated hourly table
SELECT count() FROM sensors.readings_hourly;

-- Check data skipping index exists
SELECT name, type, expr
FROM system.data_skipping_indices
WHERE database = 'sensors';
```

---

## Deduplication demonstration

Run this in the ClickHouse shell to understand `ReplacingMergeTree` behaviour:

```sql
-- 1. Insert a row
INSERT INTO sensors.readings
    (sensor_id, sensor_type, location, lat, lon, timestamp, temperature, version)
VALUES (99999, 'DHT22', 1, 48.85, 2.35, '2024-01-01 12:00:00', 22.5, 1000);

-- 2. Insert the same key with a higher version (simulates an update/correction)
INSERT INTO sensors.readings
    (sensor_id, sensor_type, location, lat, lon, timestamp, temperature, version)
VALUES (99999, 'DHT22', 1, 48.85, 2.35, '2024-01-01 12:00:00', 23.1, 2000);

-- 3. Without FINAL — you may see both rows (before background merge)
SELECT sensor_id, timestamp, temperature, version
FROM sensors.readings
WHERE sensor_id = 99999;

-- 4. With FINAL — always returns only the winning row (version=2000)
SELECT sensor_id, timestamp, temperature, version
FROM sensors.readings FINAL
WHERE sensor_id = 99999;
-- Expected: only temperature=23.1

-- 5. Force immediate merge (avoid in production — for demo only)
OPTIMIZE TABLE sensors.readings FINAL;

-- 6. Now even without FINAL the duplicate is gone
SELECT sensor_id, timestamp, temperature, version
FROM sensors.readings
WHERE sensor_id = 99999;
-- Expected: only temperature=23.1
```

---

## Tests

Save as `tests/test_m2_schema.sh`:

```bash
#!/usr/bin/env bash
# SensorHouse – Milestone 2: Schema and deduplication tests
set -euo pipefail
PASS=0; FAIL=0

CH="docker exec sensorhouse-clickhouse clickhouse-client \
    --user default --password sensorhouse --database sensors \
    --format TabSeparated --query"

check() {
  local desc="$1" query="$2" expected="$3"
  local result
  result=$($CH "$query" 2>/dev/null | tr -d '[:space:]') || result=""
  if echo "$result" | grep -q "$expected"; then
    echo "  PASS  $desc"; PASS=$((PASS+1))
  else
    echo "  FAIL  $desc  (got: '${result:0:120}')"; FAIL=$((FAIL+1))
  fi
}

echo ""
echo "=== SensorHouse · Milestone 2: Schema & Deduplication ==="
echo ""

check "Table 'readings' exists" \
  "EXISTS TABLE sensors.readings" "1"

check "Table 'readings_hourly' exists" \
  "EXISTS TABLE sensors.readings_hourly" "1"

check "Materialized view exists" \
  "SELECT count() FROM system.tables WHERE database='sensors' AND name='readings_hourly_mv'" "1"

check "readings uses ReplacingMergeTree" \
  "SELECT engine FROM system.tables WHERE database='sensors' AND name='readings'" "ReplacingMergeTree"

check "readings partitioned by month" \
  "SELECT partition_key FROM system.tables WHERE database='sensors' AND name='readings'" "toYYYYMM"

check "readings ordered by sensor_id, timestamp" \
  "SELECT sorting_key FROM system.tables WHERE database='sensors' AND name='readings'" "sensor_id"

check "Data skipping index on sensor_type exists" \
  "SELECT count() FROM system.data_skipping_indices WHERE database='sensors' AND table='readings'" "1"

check "Sample data loaded (> 0 rows)" \
  "SELECT count() > 0 FROM sensors.readings" "1"

check "Hourly MV populated" \
  "SELECT count() > 0 FROM sensors.readings_hourly" "1"

# Deduplication test
$CH "INSERT INTO sensors.readings (sensor_id, sensor_type, location, lat, lon, timestamp, temperature, version) VALUES (88888, 'DHT22', 1, 0.0, 0.0, '2020-01-01 00:00:00', 10.0, 100)" 2>/dev/null
$CH "INSERT INTO sensors.readings (sensor_id, sensor_type, location, lat, lon, timestamp, temperature, version) VALUES (88888, 'DHT22', 1, 0.0, 0.0, '2020-01-01 00:00:00', 20.0, 200)" 2>/dev/null

check "FINAL deduplication keeps highest version" \
  "SELECT temperature FROM sensors.readings FINAL WHERE sensor_id=88888 AND timestamp='2020-01-01 00:00:00'" "20"

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""
[ "$FAIL" -eq 0 ] && echo "✓ Milestone 2 COMPLETE" || { echo "✗ Fix failures before proceeding"; exit 1; }
```

Run it:

```bash
chmod +x tests/test_m2_schema.sh
bash tests/test_m2_schema.sh
```

### Expected output

```
=== SensorHouse · Milestone 2: Schema & Deduplication ===

  PASS  Table 'readings' exists
  PASS  Table 'readings_hourly' exists
  PASS  Materialized view exists
  PASS  readings uses ReplacingMergeTree
  PASS  readings partitioned by month
  PASS  readings ordered by sensor_id, timestamp
  PASS  Data skipping index on sensor_type exists
  PASS  Sample data loaded (> 0 rows)
  PASS  Hourly MV populated
  PASS  FINAL deduplication keeps highest version

Results: 10 passed, 0 failed

✓ Milestone 2 COMPLETE
```

---

## Best practices applied in this milestone

| Practice | Applied where |
|---|---|
| `LowCardinality(String)` for low-distinct columns | `sensor_type` |
| `Float32` not `Float64` for sensor values | All measurement columns |
| `MATERIALIZED` column for free derived data | `date` from `timestamp` |
| Partition key = time unit appropriate to data volume | `toYYYYMM(timestamp)` |
| Primary key low-cardinality first | `sensor_id` before `timestamp` |
| Data skipping index on filter-heavy column | `sensor_type` |
| Materialized View for pre-aggregation | `readings_hourly_mv` |
| `ReplacingMergeTree` with explicit `version` column | Deduplication |

---

## Definition of done

- [ ] All 4 init SQL files execute without errors on container start
- [ ] `SHOW TABLES IN sensors` shows `readings`, `readings_hourly`, `readings_hourly_mv`
- [ ] `SELECT count() FROM sensors.readings` returns > 0
- [ ] `SELECT count() FROM sensors.readings_hourly` returns > 0
- [ ] Deduplication demo shows `FINAL` returns only the highest-version row
- [ ] All 10 automated tests pass
