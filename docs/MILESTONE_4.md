# Milestone 4 — REST API & Grafana Dashboards

> **Project**: SensorHouse
> **Prerequisite**: Milestone 3 complete — data is flowing from Kafka into ClickHouse.
> **Goal**: Expose the five most useful analytical queries as a documented REST API (FastAPI), provision four Grafana dashboards, add a TTL policy and query profiling, and ship the final README and CHANGELOG.

---

## What this milestone covers

- FastAPI service with 5 analytical endpoints
- ClickHouse native driver integration (`clickhouse-connect`)
- OpenAPI documentation auto-generated
- Four Grafana dashboards (provisioned automatically from JSON)
- Grafana alerting on PM2.5 threshold
- TTL policy on `sensors.readings`
- Query profiling with `EXPLAIN` and `system.query_log`
- Final README and CHANGELOG
- End-to-end integration test

---

## Project structure additions

```
sensorhouse/
├── api/
│   ├── Dockerfile              ← updated
│   ├── requirements.txt        ← updated
│   ├── main.py                 ← full implementation
│   └── db.py                   ← ClickHouse connection helper
└── grafana/
    └── provisioning/
        └── dashboards/
            ├── dashboards.yml
            ├── overview.json
            ├── geo_heatmap.json
            ├── pm25.json
            └── hot_humid.json
```

---

## Step-by-step setup

### 1. Update `api/requirements.txt`

```
fastapi==0.111.0
uvicorn[standard]==0.29.0
clickhouse-connect==0.7.16
python-dotenv==1.0.1
```

### 2. Create `api/db.py`

```python
"""
Shared ClickHouse client — connection pool re-used across requests.
"""
import os
import clickhouse_connect
from dotenv import load_dotenv

load_dotenv()

_client = None


def get_client():
    global _client
    if _client is None:
        _client = clickhouse_connect.get_client(
            host=os.getenv("CLICKHOUSE_HOST", "clickhouse"),
            port=int(os.getenv("CLICKHOUSE_PORT", 8123)),
            username=os.getenv("CLICKHOUSE_USER", "default"),
            password=os.getenv("CLICKHOUSE_PASSWORD", "sensorhouse"),
            database=os.getenv("CLICKHOUSE_DB", "sensors"),
            connect_timeout=10,
            query_retries=2,
        )
    return _client
```

### 3. Create `api/main.py` (full implementation)

```python
"""
SensorHouse API — v1 endpoints wrapping the most popular ClickHouse queries.
"""
from fastapi import FastAPI, Query, HTTPException
from fastapi.responses import JSONResponse
from typing import Optional
from db import get_client

app = FastAPI(
    title="SensorHouse API",
    description="REST API over the Sensor.Community environmental dataset stored in ClickHouse.",
    version="1.0.0",
)


# ─────────────────────────────────────────────
# Health
# ─────────────────────────────────────────────

@app.get("/health", tags=["meta"])
def health():
    """Liveness probe — always returns 200 if the service is up."""
    return {"status": "ok", "service": "sensorhouse-api"}


@app.get("/health/db", tags=["meta"])
def health_db():
    """Checks that ClickHouse is reachable and has data."""
    try:
        result = get_client().query("SELECT count() FROM sensors.readings")
        return {"status": "ok", "row_count": result.first_row[0]}
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))


# ─────────────────────────────────────────────
# Endpoint 1: daily row counts (sensor network growth)
# ─────────────────────────────────────────────

@app.get("/api/v1/daily-counts", tags=["analytics"])
def daily_counts(
    start: str = Query("2019-01-01", description="Start date YYYY-MM-DD"),
    end:   str = Query("2020-01-01", description="End date YYYY-MM-DD"),
):
    """
    Number of sensor readings per day — shows how the network grew over time.
    Backed by the fast MATERIALIZED date column.
    """
    sql = """
        SELECT
            date,
            count() AS readings
        FROM sensors.readings
        WHERE date BETWEEN toDate({start:String}) AND toDate({end:String})
        GROUP BY date
        ORDER BY date
    """
    result = get_client().query(sql, parameters={"start": start, "end": end})
    return [{"date": str(row[0]), "readings": row[1]} for row in result.result_rows]


# ─────────────────────────────────────────────
# Endpoint 2: hottest and most humid days
# ─────────────────────────────────────────────

@app.get("/api/v1/hottest-days", tags=["analytics"])
def hottest_days(
    min_temp:     float = Query(40.0,  description="Minimum temperature °C"),
    min_humidity: float = Query(90.0,  description="Minimum humidity %"),
    limit:        int   = Query(100,   ge=1, le=1000),
):
    """
    Days with extreme heat and humidity — useful for climate analysis.
    """
    sql = """
        SELECT
            toYYYYMMDD(timestamp) AS day,
            count()               AS events,
            round(avg(temperature), 2) AS avg_temp,
            round(avg(humidity), 2)    AS avg_humidity
        FROM sensors.readings
        WHERE temperature >= {min_temp:Float32}
          AND temperature <= 60
          AND humidity >= {min_humidity:Float32}
        GROUP BY day
        ORDER BY events DESC
        LIMIT {limit:UInt32}
    """
    result = get_client().query(sql, parameters={
        "min_temp":     min_temp,
        "min_humidity": min_humidity,
        "limit":        limit,
    })
    return [{"day": row[0], "events": row[1], "avg_temp": row[2], "avg_humidity": row[3]}
            for row in result.result_rows]


# ─────────────────────────────────────────────
# Endpoint 3: sensor history time-series
# ─────────────────────────────────────────────

@app.get("/api/v1/sensors/{sensor_id}/history", tags=["sensors"])
def sensor_history(
    sensor_id: int,
    start:  str = Query("2019-06-01", description="Start datetime YYYY-MM-DD"),
    end:    str = Query("2019-07-01", description="End datetime YYYY-MM-DD"),
    metric: str = Query("temperature", description="Column name to return"),
):
    """
    Full time-series for one sensor. Use FINAL for deduplicated results.
    """
    allowed_metrics = {
        "temperature", "humidity", "pressure", "P1", "P2", "P0"
    }
    if metric not in allowed_metrics:
        raise HTTPException(status_code=400, detail=f"metric must be one of {allowed_metrics}")

    sql = f"""
        SELECT timestamp, {metric}
        FROM sensors.readings FINAL
        WHERE sensor_id = {{sensor_id:UInt32}}
          AND timestamp BETWEEN {{start:String}} AND {{end:String}}
          AND {metric} > 0
        ORDER BY timestamp
        LIMIT 10000
    """
    result = get_client().query(sql, parameters={
        "sensor_id": sensor_id,
        "start": start,
        "end": end,
    })
    return [{"timestamp": str(row[0]), metric: row[1]} for row in result.result_rows]


# ─────────────────────────────────────────────
# Endpoint 4: top locations by PM2.5 pollution
# ─────────────────────────────────────────────

@app.get("/api/v1/top-pm25", tags=["analytics"])
def top_pm25(
    limit: int = Query(20, ge=1, le=200),
    start: str = Query("2019-01-01"),
    end:   str = Query("2020-01-01"),
):
    """
    Top locations by average PM2.5 particulate matter concentration.
    Uses the hourly pre-aggregated table for speed.
    """
    sql = """
        SELECT
            sensor_id,
            any(lat)          AS lat,
            any(lon)          AS lon,
            round(avg(avg_P2), 3) AS avg_pm25,
            sum(sample_count) AS total_samples
        FROM sensors.readings_hourly
        WHERE hour BETWEEN toDateTime({start:String}) AND toDateTime({end:String})
          AND avg_P2 > 0
        GROUP BY sensor_id
        ORDER BY avg_pm25 DESC
        LIMIT {limit:UInt32}
    """
    result = get_client().query(sql, parameters={"start": start, "end": end, "limit": limit})
    return [
        {
            "sensor_id":     row[0],
            "lat":           row[1],
            "lon":           row[2],
            "avg_pm25":      row[3],
            "total_samples": row[4],
        }
        for row in result.result_rows
    ]


# ─────────────────────────────────────────────
# Endpoint 5: geographic heatmap data
# ─────────────────────────────────────────────

@app.get("/api/v1/geo-heatmap", tags=["analytics"])
def geo_heatmap(
    metric:     str   = Query("temperature", description="Metric to aggregate"),
    resolution: float = Query(1.0, description="Grid cell size in degrees"),
    start:      str   = Query("2019-06-01"),
    end:        str   = Query("2019-07-01"),
):
    """
    Aggregates sensor values onto a lat/lon grid — feeds the Grafana Geomap panel.
    """
    allowed_metrics = {"temperature", "humidity", "pressure", "avg_P1", "avg_P2"}
    if metric not in allowed_metrics:
        raise HTTPException(status_code=400, detail=f"metric must be one of {allowed_metrics}")

    col = metric if metric.startswith("avg_") else f"avg_{metric}"

    sql = f"""
        SELECT
            round(any(lat) / {{res:Float32}}) * {{res:Float32}}  AS lat_bucket,
            round(any(lon) / {{res:Float32}}) * {{res:Float32}}  AS lon_bucket,
            round(avg({col}), 2)                                  AS value
        FROM sensors.readings_hourly
        WHERE hour BETWEEN toDateTime({{start:String}}) AND toDateTime({{end:String}})
          AND {col} > 0
        GROUP BY lat_bucket, lon_bucket
        HAVING value > 0
        ORDER BY value DESC
        LIMIT 5000
    """
    result = get_client().query(sql, parameters={"res": resolution, "start": start, "end": end})
    return [{"lat": row[0], "lon": row[1], "value": row[2]} for row in result.result_rows]
```

### 4. Add TTL to `sensors.readings`

Run this once against the running ClickHouse:

```bash
docker exec -it sensorhouse-clickhouse \
  clickhouse-client --user default --password sensorhouse \
  --query "
    ALTER TABLE sensors.readings
    MODIFY TTL date + INTERVAL 5 YEAR;
  "
```

This instructs ClickHouse to automatically drop data older than 5 years during background merges. Safe to set even with fresh data.

---

## Grafana dashboards

Grafana picks up JSON files from `grafana/provisioning/dashboards/` automatically (thanks to `dashboards.yml`). Create one JSON file per dashboard.

### Overview dashboard (`overview.json`)

Key panels:
- **Time series**: `SELECT date, count() FROM sensors.readings GROUP BY date ORDER BY date` — sensor activity over time
- **Stat**: total row count
- **Stat**: distinct sensor count: `SELECT uniq(sensor_id) FROM sensors.readings`

### PM2.5 dashboard (`pm25.json`)

Key panels:
- **Time series**: hourly average PM2.5: `SELECT hour, avg(avg_P2) FROM sensors.readings_hourly GROUP BY hour ORDER BY hour`
- **Bar gauge**: top 10 sensors by PM2.5
- **Alert**: fire when `avg_P2 > 25 µg/m³` (WHO safe limit)

### Hot & humid days (`hot_humid.json`)

Key panels:
- **Bar chart**: `SELECT toYYYYMMDD(timestamp) AS day, count() FROM sensors.readings WHERE temperature >= 40 AND humidity >= 90 GROUP BY day ORDER BY day`

### Geo heatmap (`geo_heatmap.json`)

Key panels:
- **Geomap**: lat/lon from `/api/v1/geo-heatmap` (proxy via Infinity datasource) or directly from ClickHouse using `any(lat), any(lon), avg(avg_temp)` grouped by location.

> Grafana dashboard JSON files are verbose (~200–500 lines each). Generate them by building the dashboards manually in the Grafana UI at `http://localhost:3000`, then exporting via **Dashboard → Share → Export → Save to file**, and placing the file in `grafana/provisioning/dashboards/`.

---

## How to run this milestone

### Restart the API container (after code changes)

```bash
docker compose up -d --build api
docker compose logs -f api
```

### Apply TTL policy

```bash
docker exec -it sensorhouse-clickhouse \
  clickhouse-client --user default --password sensorhouse \
  --query "ALTER TABLE sensors.readings MODIFY TTL date + INTERVAL 5 YEAR;"
```

### Verify TTL set

```bash
docker exec sensorhouse-clickhouse \
  clickhouse-client --user default --password sensorhouse \
  --query "SELECT ttl_expression FROM system.tables WHERE database='sensors' AND name='readings'"
# Expected: date + toIntervalYear(5)
```

### Test every API endpoint

```bash
BASE=http://localhost:8000

curl -s "$BASE/health"
curl -s "$BASE/health/db"
curl -s "$BASE/api/v1/daily-counts?start=2019-06-01&end=2019-07-01" | python3 -m json.tool | head -30
curl -s "$BASE/api/v1/hottest-days?min_temp=35&min_humidity=80&limit=5" | python3 -m json.tool
curl -s "$BASE/api/v1/sensors/9119/history?start=2019-06-01&end=2019-06-30&metric=temperature" | python3 -m json.tool | head -20
curl -s "$BASE/api/v1/top-pm25?limit=5" | python3 -m json.tool
curl -s "$BASE/api/v1/geo-heatmap?metric=temperature&resolution=2.0" | python3 -m json.tool | head -20

# Interactive API docs
open http://localhost:8000/docs
```

### Query profiling

```bash
docker exec -it sensorhouse-clickhouse \
  clickhouse-client --user default --password sensorhouse --database sensors
```

Inside the shell:

```sql
-- EXPLAIN: see the query execution plan
EXPLAIN
SELECT date, count()
FROM sensors.readings
WHERE date BETWEEN '2019-06-01' AND '2019-07-01'
GROUP BY date;

-- Check recent query performance
SELECT
    query_duration_ms,
    read_rows,
    formatReadableSize(read_bytes)  AS read_bytes,
    result_rows,
    query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND database = 'sensors'
ORDER BY event_time DESC
LIMIT 10;

-- Find slow queries
SELECT
    query,
    query_duration_ms
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 500
ORDER BY query_duration_ms DESC
LIMIT 5;
```

---

## Tests

Save as `tests/test_m4_api.sh`:

```bash
#!/usr/bin/env bash
# SensorHouse – Milestone 4: API and Grafana tests
set -euo pipefail
PASS=0; FAIL=0
BASE="http://localhost:8000"

CH="docker exec sensorhouse-clickhouse clickhouse-client \
    --user default --password sensorhouse --database sensors \
    --format TabSeparated --query"

check_http() {
  local desc="$1" url="$2" expected="$3"
  local result
  result=$(curl -s "$url") || result=""
  if echo "$result" | grep -q "$expected"; then
    echo "  PASS  $desc"; PASS=$((PASS+1))
  else
    echo "  FAIL  $desc  (got: '${result:0:120}')"; FAIL=$((FAIL+1))
  fi
}

check_status() {
  local desc="$1" url="$2" expected_code="$3"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$url") || code="000"
  if [ "$code" = "$expected_code" ]; then
    echo "  PASS  $desc"; PASS=$((PASS+1))
  else
    echo "  FAIL  $desc  (HTTP $code, expected $expected_code)"; FAIL=$((FAIL+1))
  fi
}

check_ch() {
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
echo "=== SensorHouse · Milestone 4: API & Grafana ==="
echo ""
echo "--- API endpoints ---"

check_http "GET /health returns ok" \
  "$BASE/health" "ok"

check_http "GET /health/db connects to ClickHouse" \
  "$BASE/health/db" "row_count"

check_status "GET /api/v1/daily-counts returns 200" \
  "$BASE/api/v1/daily-counts?start=2019-06-01&end=2019-07-01" "200"

check_http "GET /api/v1/daily-counts returns JSON array" \
  "$BASE/api/v1/daily-counts?start=2019-06-01&end=2019-07-01" "date"

check_status "GET /api/v1/hottest-days returns 200" \
  "$BASE/api/v1/hottest-days?min_temp=35&min_humidity=70" "200"

check_status "GET /api/v1/sensors/9119/history returns 200" \
  "$BASE/api/v1/sensors/9119/history?start=2019-06-01&end=2019-06-30" "200"

check_status "GET /api/v1/top-pm25 returns 200" \
  "$BASE/api/v1/top-pm25?limit=10" "200"

check_status "GET /api/v1/geo-heatmap returns 200" \
  "$BASE/api/v1/geo-heatmap?metric=temperature&resolution=2.0" "200"

check_http "GET /api/v1/top-pm25 contains lat field" \
  "$BASE/api/v1/top-pm25?limit=5" "lat"

check_http "GET /api/v1/geo-heatmap contains value field" \
  "$BASE/api/v1/geo-heatmap?metric=temperature&resolution=2.0" "value"

check_status "Invalid metric returns 400" \
  "$BASE/api/v1/sensors/1/history?metric=invalid_col" "400"

check_status "OpenAPI docs return 200" \
  "$BASE/docs" "200"

echo ""
echo "--- ClickHouse TTL & profiling ---"

check_ch "TTL is set on readings table" \
  "SELECT length(ttl_expression) > 0 FROM system.tables WHERE database='sensors' AND name='readings'" "1"

check_ch "query_log has entries" \
  "SELECT count() > 0 FROM system.query_log WHERE type='QueryFinish' AND database='sensors'" "1"

echo ""
echo "--- Grafana ---"

check_status "Grafana UI reachable" \
  "http://localhost:3000/login" "200"

check_http "Grafana API: ClickHouse datasource provisioned" \
  "http://admin:sensorhouse@localhost:3000/api/datasources" "ClickHouse"

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""
[ "$FAIL" -eq 0 ] && echo "✓ Milestone 4 COMPLETE — SensorHouse workshop finished!" \
  || { echo "✗ Fix failures before marking complete"; exit 1; }
```

Run it:

```bash
chmod +x tests/test_m4_api.sh
bash tests/test_m4_api.sh
```

### Expected output

```
=== SensorHouse · Milestone 4: API & Grafana ===

--- API endpoints ---
  PASS  GET /health returns ok
  PASS  GET /health/db connects to ClickHouse
  PASS  GET /api/v1/daily-counts returns 200
  PASS  GET /api/v1/daily-counts returns JSON array
  PASS  GET /api/v1/hottest-days returns 200
  PASS  GET /api/v1/sensors/9119/history returns 200
  PASS  GET /api/v1/top-pm25 returns 200
  PASS  GET /api/v1/geo-heatmap returns 200
  PASS  GET /api/v1/top-pm25 contains lat field
  PASS  GET /api/v1/geo-heatmap contains value field
  PASS  Invalid metric returns 400
  PASS  OpenAPI docs return 200

--- ClickHouse TTL & profiling ---
  PASS  TTL is set on readings table
  PASS  query_log has entries

--- Grafana ---
  PASS  Grafana UI reachable
  PASS  Grafana API: ClickHouse datasource provisioned

Results: 16 passed, 0 failed

✓ Milestone 4 COMPLETE — SensorHouse workshop finished!
```

---

## Final checklist: CHANGELOG.md

```markdown
# Changelog

All notable changes to SensorHouse are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.4.0] — Milestone 4: API & Dashboards
### Added
- FastAPI REST service with 5 analytical endpoints
- `/api/v1/daily-counts`, `/hottest-days`, `/sensors/{id}/history`, `/top-pm25`, `/geo-heatmap`
- OpenAPI docs at `/docs`
- TTL policy: data older than 5 years auto-expired
- Grafana dashboards: overview, PM2.5 trends, geo heatmap, hot & humid days
- Grafana alerting on PM2.5 threshold
- Query profiling via `system.query_log` and `EXPLAIN`

## [0.3.0] — Milestone 3: Kafka Ingestion
### Added
- Python Kafka producer (replays S3 CSV as JSON events)
- Kafka engine table `readings_kafka` in ClickHouse
- Materialized View `readings_kafka_mv` routing Kafka → `sensors.readings`
- Redpanda Console UI for Kafka topic inspection
- Consumer lag monitoring via `system.kafka_consumers`

## [0.2.0] — Milestone 2: Schema & Deduplication
### Added
- `sensors.readings` table (ReplacingMergeTree, versioned deduplication)
- `sensors.readings_hourly` pre-aggregation table
- Materialized View `readings_hourly_mv`
- Data skipping index on `sensor_type`
- Sample data load from public S3
- Init SQL scripts auto-applied on container start

## [0.1.0] — Milestone 1: Infrastructure
### Added
- Docker Compose stack: Zookeeper, Kafka, Redpanda Console, ClickHouse, Grafana, FastAPI
- Health checks and dependency ordering
- Environment variable management via `.env`
- Grafana datasource auto-provisioning
- FastAPI skeleton with `/health` endpoint
```

---

## Definition of done

- [ ] All 5 API endpoints return `200` with non-empty JSON
- [ ] Invalid metric returns `400` (input validation works)
- [ ] TTL is set: `ttl_expression` in `system.tables` is non-empty
- [ ] `system.query_log` contains query history entries
- [ ] Grafana loads at `http://localhost:3000` with ClickHouse datasource connected
- [ ] At least one dashboard panel loads data successfully
- [ ] CHANGELOG.md has entries for all 4 milestones
- [ ] All 16 automated tests pass
