from fastapi import FastAPI

app = FastAPI(title="SensorHouse API")


@app.get("/health")
def health():
    return {"status": "ok", "service": "sensorhouse-api"}
