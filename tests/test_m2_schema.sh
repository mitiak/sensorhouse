#!/usr/bin/env bash
set -euo pipefail

CH="http://localhost:8123"
AUTH="user=default&password=sensorhouse"
PASS=0
FAIL=0

check() {
    local name="$1"
    local cmd="$2"
    if eval "$cmd" &>/dev/null; then
        echo "  PASS  $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name"
        FAIL=$((FAIL + 1))
    fi
}

ch() {
    curl -sf "${CH}/?${AUTH}&query=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1")"
}

echo "=== SensorHouse M2 Schema Tests ==="
echo

# 1. Database
check "sensors database exists" \
    "ch 'SHOW DATABASES' | grep -q sensors"

# 2. Tables
check "sensors.readings table exists" \
    "ch 'SHOW TABLES FROM sensors' | grep -q readings"

check "sensors.readings_hourly table exists" \
    "ch 'SHOW TABLES FROM sensors' | grep -q readings_hourly"

# 3. Materialized View
check "sensors.readings_hourly_mv MV exists" \
    "ch \"SELECT name FROM system.tables WHERE database='sensors' AND engine='MaterializedView'\" | grep -q readings_hourly_mv"

# 4. Data loaded (S3 insert)
check "sensors.readings row count > 0" \
    "ch 'SELECT count() FROM sensors.readings' | grep -qv '^0$'"

# 5. MV populated
check "sensors.readings_hourly row count > 0" \
    "ch 'SELECT count() FROM sensors.readings_hourly' | grep -qv '^0$'"

# 6. ReplacingMergeTree deduplication
CONTAINER="sensorhouse-clickhouse-1"
docker exec "$CONTAINER" clickhouse-client --password sensorhouse --query \
    "INSERT INTO sensors.readings (sensor_id, sensor_type, location, lat, lon, timestamp, temperature, version) VALUES (999999, 'TEST', 0, 0, 0, '2019-06-01 00:00:00', 25.0, 1), (999999, 'TEST', 0, 0, 0, '2019-06-01 00:00:00', 30.0, 2)" &>/dev/null || true

check "ReplacingMergeTree deduplication works" \
    "docker exec $CONTAINER clickhouse-client --password sensorhouse \
     --query 'SELECT count() FROM sensors.readings FINAL WHERE sensor_id = 999999' | grep -q '^1$'"

# 7. Deduplication winner has higher version value
check "ReplacingMergeTree keeps highest version" \
    "docker exec $CONTAINER clickhouse-client --password sensorhouse \
     --query 'SELECT temperature FROM sensors.readings FINAL WHERE sensor_id = 999999' | grep -q '^30'"

# 8. Hourly rollup returns valid avg
check "avgMerge(avg_temp) returns non-zero float" \
    "ch 'SELECT avgMerge(avg_temp) FROM sensors.readings_hourly LIMIT 1' | grep -qE '^[0-9]+\.[0-9]+'"

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

[ "$FAIL" -eq 0 ]
