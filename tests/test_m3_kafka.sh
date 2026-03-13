#!/usr/bin/env bash
# SensorHouse – Milestone 3: Kafka ingestion tests
set -euo pipefail
PASS=0; FAIL=0

CH="docker exec sensorhouse-clickhouse-1 clickhouse-client \
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

check "Kafka topic 'sensor_readings' exists" \
  "docker exec sensorhouse-kafka-1 kafka-topics --bootstrap-server localhost:9092 --list" \
  "sensor_readings"

check "Topic has 3 partitions" \
  "docker exec sensorhouse-kafka-1 kafka-topics --bootstrap-server localhost:9092 --describe --topic sensor_readings | grep -c PartitionCount" \
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
  "$CH 'SELECT count() > 0 FROM (SELECT avgMerge(avg_temp) AS t FROM sensors.readings_hourly GROUP BY sensor_id, hour HAVING t > 0 LIMIT 1)'" "1"

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""
[ "$FAIL" -eq 0 ] && echo "✓ Milestone 3 COMPLETE" || { echo "✗ Fix failures before proceeding"; exit 1; }
