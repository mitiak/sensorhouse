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
