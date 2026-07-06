"""
Supervision Dashboard Service (FastAPI)
-----------------------------------------
Backend API only — the frontend itself is explicitly out of scope.
"""

import os
from datetime import datetime, timezone

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(
    title="Supervision Dashboard API",
    description="Backend API for the reception robot supervision dashboard.",
    version="0.1.0",
)

# CORRECTION : Le port est lu depuis la variable d'environnement
SERVICE_PORT = int(os.environ.get("SERVICE_PORT", 8003))
ROBOT_SERVICE_URL = os.environ.get("ROBOT_SERVICE_URL", "http://robot-service:8002")

# In-memory visitor log store
_visitor_logs: list[dict] = []


class VisitorLogEntry(BaseModel):
    visitor_name: str
    purpose: str


class MoveRequest(BaseModel):
    dx: float
    dy: float
    heading_deg: float | None = None


@app.get("/health")
def health():
    """Liveness/readiness probe for Docker healthcheck."""
    return {"status": "ok", "service": "dashboard-service"}


@app.get("/logs")
def list_logs():
    return {"count": len(_visitor_logs), "logs": _visitor_logs}


@app.post("/logs")
def add_log(entry: VisitorLogEntry):
    log = entry.model_dump()
    log["timestamp"] = datetime.now(timezone.utc).isoformat()
    _visitor_logs.append(log)
    return log


@app.post("/robot/move")
async def relay_move_command(cmd: MoveRequest):
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            resp = await client.post(f"{ROBOT_SERVICE_URL}/robot/move", json=cmd.model_dump())
            resp.raise_for_status()
        except httpx.HTTPError as exc:
            raise HTTPException(status_code=502, detail=f"Robot service unreachable: {exc}")
    return resp.json()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=SERVICE_PORT, reload=True)