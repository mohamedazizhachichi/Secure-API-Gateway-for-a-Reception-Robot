"""
Supervision Dashboard Service (FastAPI)
-----------------------------------------
Backend API only — the frontend itself is explicitly out of scope
(Cahier des Charges V3, section 3). This service exposes read endpoints
for visitor logs and a proxy-style endpoint to relay move commands to the
simulated robot service.

Auth note (Sprint 3): as with robot-service, token verification is expected
to happen at the Kong layer. Role distinctions (Admin vs Operator, per the
permissions matrix) will be enforced via Kong RBAC/ACL plugins in Sprint 4,
not duplicated here.
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

SERVICE_PORT = int(os.environ.get("SERVICE_PORT", 8002))
# ENF-06: never hardcode the robot's URL, even though only the simulated
# robot is in scope for this internship.
ROBOT_SERVICE_URL = os.environ.get("ROBOT_SERVICE_URL", "http://robot-service:8001")

# In-memory visitor log store (placeholder — Sprint 4/5 will back this with
# PostgreSQL + real logging pipeline via Loki/Grafana)
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
    """
    EF-04 support: expose visitor logs for consultation.
    Per the permissions matrix, only Admin/Operator roles may call this
    in the finished system — enforced at the gateway, not here.
    """
    return {"count": len(_visitor_logs), "logs": _visitor_logs}


@app.post("/logs")
def add_log(entry: VisitorLogEntry):
    """Record a visitor interaction (simulated reception event)."""
    log = entry.model_dump()
    log["timestamp"] = datetime.now(timezone.utc).isoformat()
    _visitor_logs.append(log)
    return log


@app.post("/robot/move")
async def relay_move_command(cmd: MoveRequest):
    """
    Relays a movement command to the simulated robot service.
    Demonstrates ENF-06 in practice: this call uses ROBOT_SERVICE_URL from
    the environment rather than a hardcoded address.
    """
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
