"""
SensorHouse Kafka Producer
Streams sensor readings from the S3 CSV dataset into Kafka as JSON events.
Supports: replay speed multiplier, sensor_type filter, row limit.
"""
import csv
import io
import json
import logging
import os
import time
import urllib.request

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
        dctx = zstd.ZstdDecompressor()
        log.info("Decompressing …")
        with dctx.stream_reader(resp) as reader:
            text = reader.read().decode("utf-8")
    csv_reader = csv.DictReader(io.StringIO(text), delimiter=";")
    yield from csv_reader


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
        "ts":          row.get("timestamp", ""),
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
