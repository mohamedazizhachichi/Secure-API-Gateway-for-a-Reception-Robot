"""
Supervision Dashboard Service (FastAPI)
-----------------------------------------
Backend API only — the frontend itself is explicitly out of scope.
"""

import os
from datetime import datetime, timezone

import httpx
from fastapi import Depends, FastAPI, HTTPException, Request
from jwt_middleware import JWTAuthMiddleware
from pydantic import BaseModel
from rbac import require_role

app = FastAPI(
    title="Supervision Dashboard API",
    description="Backend API for the reception robot supervision dashboard.",
    version="0.1.0",
)

# Ajouter le middleware JWT (défense en profondeur)
app.add_middleware(JWTAuthMiddleware, exclude_paths={"/health", "/docs", "/openapi.json", "/redoc"})

# CORRECTION : Le port est lu depuis la variable d'environnement
SERVICE_PORT = int(os.environ.get("SERVICE_PORT", "8003"))
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


@app.get("/dashboard/logs")
def list_logs():
    return {"count": len(_visitor_logs), "logs": _visitor_logs}


@app.post("/dashboard/logs")
def add_log(entry: VisitorLogEntry):
    log = entry.model_dump()
    log["timestamp"] = datetime.now(timezone.utc).isoformat()
    _visitor_logs.append(log)
    return log


@app.post("/dashboard/robot/config")
async def relay_config_update(
    request: Request,
    config: dict,
    _: None = Depends(require_role("admin"))
):
    token = request.headers.get("Authorization", "")
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            resp = await client.post(
                f"{ROBOT_SERVICE_URL}/robot/config",
                json=config,
                headers={"Authorization": token}
            )
            resp.raise_for_status()
        except httpx.HTTPError as exc:
            raise HTTPException(status_code=502, detail=f"Robot service unreachable: {exc}")
    return resp.json()


@app.post("/dashboard/robot/move")
async def relay_move_command(
    request: Request,
    cmd: MoveRequest,
    _: None = Depends(require_role("admin" , "operator"))
):
    token = request.headers.get("Authorization", "")
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            resp = await client.post(
                f"{ROBOT_SERVICE_URL}/robot/move",
                json=cmd.model_dump(),
                headers={"Authorization": token}  # Ajouter cette ligne
            )
            resp.raise_for_status()
        except httpx.HTTPError as exc:
            raise HTTPException(status_code=502, detail=f"Robot service unreachable: {exc}")
    return resp.json()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=SERVICE_PORT, reload=True)