"""
SensorHouse API — v1 endpoints wrapping the most popular ClickHouse queries.
"""
from fastapi import FastAPI, HTTPException, Query

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
    end: str = Query("2020-01-01", description="End date YYYY-MM-DD"),
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
    min_temp: float = Query(40.0, description="Minimum temperature °C"),
    min_humidity: float = Query(90.0, description="Minimum humidity %"),
    limit: int = Query(100, ge=1, le=1000),
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
    result = get_client().query(
        sql,
        parameters={
            "min_temp": min_temp,
            "min_humidity": min_humidity,
            "limit": limit,
        },
    )
    return [
        {"day": row[0], "events": row[1], "avg_temp": row[2], "avg_humidity": row[3]}
        for row in result.result_rows
    ]


# ─────────────────────────────────────────────
# Endpoint 3: sensor history time-series
# ─────────────────────────────────────────────


@app.get("/api/v1/sensors/{sensor_id}/history", tags=["sensors"])
def sensor_history(
    sensor_id: int,
    start: str = Query("2019-06-01", description="Start datetime YYYY-MM-DD"),
    end: str = Query("2019-07-01", description="End datetime YYYY-MM-DD"),
    metric: str = Query("temperature", description="Column name to return"),
):
    """
    Full time-series for one sensor. Uses FINAL for deduplicated results.
    """
    allowed_metrics = {"temperature", "humidity", "pressure", "P1", "P2", "P0"}
    if metric not in allowed_metrics:
        raise HTTPException(
            status_code=400, detail=f"metric must be one of {sorted(allowed_metrics)}"
        )

    sql = f"""
        SELECT timestamp, {metric}
        FROM sensors.readings FINAL
        WHERE sensor_id = {{sensor_id:UInt32}}
          AND timestamp BETWEEN {{start:String}} AND {{end:String}}
          AND {metric} > 0
        ORDER BY timestamp
        LIMIT 10000
    """
    result = get_client().query(
        sql,
        parameters={"sensor_id": sensor_id, "start": start, "end": end},
    )
    return [{"timestamp": str(row[0]), metric: row[1]} for row in result.result_rows]


# ─────────────────────────────────────────────
# Endpoint 4: top locations by PM2.5 pollution
# ─────────────────────────────────────────────


@app.get("/api/v1/top-pm25", tags=["analytics"])
def top_pm25(
    limit: int = Query(20, ge=1, le=200),
    start: str = Query("2019-01-01"),
    end: str = Query("2020-01-01"),
):
    """
    Top locations by average PM2.5 particulate matter concentration.
    Uses the hourly pre-aggregated table for speed.
    """
    sql = """
        SELECT
            sensor_id,
            anyMerge(lat)              AS lat,
            anyMerge(lon)              AS lon,
            round(avgMerge(avg_P2), 3) AS avg_pm25,
            sumMerge(sample_count)     AS total_samples
        FROM sensors.readings_hourly
        WHERE hour BETWEEN toDateTime({start:String}) AND toDateTime({end:String})
        GROUP BY sensor_id
        ORDER BY avg_pm25 DESC
        LIMIT {limit:UInt32}
    """
    result = get_client().query(sql, parameters={"start": start, "end": end, "limit": limit})
    return [
        {
            "sensor_id": row[0],
            "lat": row[1],
            "lon": row[2],
            "avg_pm25": row[3],
            "total_samples": row[4],
        }
        for row in result.result_rows
    ]


# ─────────────────────────────────────────────
# Endpoint 5: geographic heatmap data
# ─────────────────────────────────────────────


@app.get("/api/v1/geo-heatmap", tags=["analytics"])
def geo_heatmap(
    metric: str = Query("temperature", description="Metric to aggregate"),
    resolution: float = Query(1.0, description="Grid cell size in degrees"),
    start: str = Query("2019-06-01"),
    end: str = Query("2019-07-01"),
):
    """
    Aggregates sensor values onto a lat/lon grid — feeds the Grafana Geomap panel.
    """
    allowed_metrics = {"temperature", "humidity", "pressure", "avg_P1", "avg_P2"}
    if metric not in allowed_metrics:
        raise HTTPException(
            status_code=400, detail=f"metric must be one of {sorted(allowed_metrics)}"
        )

    # Map user-facing metric names to actual AggregatingMergeTree column names
    col_map = {
        "temperature": "avg_temp",
        "humidity": "avg_humidity",
        "pressure": "avg_pressure",
    }
    col = col_map.get(metric, metric)

    sql = f"""
        SELECT
            round(lat / {{res:Float32}}) * {{res:Float32}}  AS lat_bucket,
            round(lon / {{res:Float32}}) * {{res:Float32}}  AS lon_bucket,
            round(avg(value), 2)                            AS value
        FROM (
            SELECT
                anyMerge(lat)     AS lat,
                anyMerge(lon)     AS lon,
                avgMerge({col})   AS value
            FROM sensors.readings_hourly
            WHERE hour BETWEEN toDateTime({{start:String}}) AND toDateTime({{end:String}})
            GROUP BY sensor_id
        )
        GROUP BY lat_bucket, lon_bucket
        HAVING value > 0
        ORDER BY value DESC
        LIMIT 5000
    """
    result = get_client().query(sql, parameters={"res": resolution, "start": start, "end": end})
    return [{"lat": row[0], "lon": row[1], "value": row[2]} for row in result.result_rows]
