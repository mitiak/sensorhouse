#!/usr/bin/env bash
# SensorHouse – Milestone 4: API and Grafana tests
set -euo pipefail
PASS=0; FAIL=0
BASE="http://localhost:8000"

CH="docker exec sensorhouse-clickhouse-1 clickhouse-client \
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
  "SELECT create_table_query LIKE '%TTL%' FROM system.tables WHERE database='sensors' AND name='readings'" "1"

check_ch "query_log has entries" \
  "SELECT count() > 0 FROM system.query_log WHERE type='QueryFinish' AND databases[1]='sensors'" "1"

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
