#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0

check() {
    local name="$1"
    local cmd="$2"
    if eval "$cmd" &>/dev/null; then
        echo "  PASS  $name"
        ((PASS++))
    else
        echo "  FAIL  $name"
        ((FAIL++))
    fi
}

echo "=== SensorHouse M1 Infrastructure Tests ==="
echo

# ClickHouse
check "ClickHouse ping" \
    "curl -sf http://localhost:8123/ping | grep -q 'Ok'"

check "ClickHouse SELECT 1" \
    "curl -sf 'http://localhost:8123/?query=SELECT+1&user=default&password=sensorhouse' | grep -q '1'"

check "ClickHouse version" \
    "curl -sf 'http://localhost:8123/?query=SELECT+version()&user=default&password=sensorhouse' | grep -qE '[0-9]+\.[0-9]+'"

check "ClickHouse sensors DB exists" \
    "curl -sf 'http://localhost:8123/?query=SHOW+DATABASES&user=default&password=sensorhouse' | grep -q 'sensors'"

# Kafka
check "Kafka broker API" \
    "curl -sf http://localhost:8080/api/brokers | grep -q 'brokerIds'"

# Redpanda Console
check "Redpanda Console HTTP 200" \
    "curl -sf http://localhost:8080 -o /dev/null -w '%{http_code}' | grep -q '200'"

# Grafana
check "Grafana HTTP 200" \
    "curl -sf http://localhost:3000/api/health | grep -q 'ok'"

# API
check "API /health returns ok" \
    "curl -sf http://localhost:8000/health | grep -q '\"status\":\"ok\"'"

check "API /docs HTTP 200" \
    "curl -sf http://localhost:8000/docs -o /dev/null -w '%{http_code}' | grep -q '200'"

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

[ "$FAIL" -eq 0 ]
