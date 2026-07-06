"""
Simulated Reception Robot Service (FastAPI)
--------------------------------------------
EF-06: exposes a simulated robot API, independent of any physical robot.
No hardware, no firmware — this process only *pretends* to move a robot.
"""

import os
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(
    title="Simulated Reception Robot API",
    description="Simulation-only service imitating a reception robot. "
                 "No physical robot is connected at any point in this project.",
    version="0.1.0",
)

# CORRECTION : Le port est lu DEPUIS LA VARIABLE D'ENVIRONNEMENT
# et stocké dans une variable globale (visible par uvicorn)
SERVICE_PORT = int(os.environ.get("SERVICE_PORT", 8002))

# In-memory simulated robot state
_robot_state = {
    "position": {"x": 0.0, "y": 0.0, "heading_deg": 0.0},
    "status": "idle",
    "last_command_at": None,
}


class MoveCommand(BaseModel):
    dx: float
    dy: float
    heading_deg: float | None = None


class MoveResult(BaseModel):
    accepted: bool
    position: dict
    status: str
    timestamp: str


@app.get("/health")
def health():
    """Liveness/readiness probe for Docker healthcheck."""
    return {"status": "ok", "service": "robot-service"}


@app.get("/robot/state")
def get_state():
    """Read-only snapshot of the simulated robot's current state."""
    return _robot_state


@app.post("/robot/move", response_model=MoveResult)
def move_robot(cmd: MoveCommand):
    """
    Simulated movement command.
    """
    if _robot_state["status"] == "moving":
        raise HTTPException(status_code=409, detail="Robot is already executing a movement")

    _robot_state["position"]["x"] += cmd.dx
    _robot_state["position"]["y"] += cmd.dy
    if cmd.heading_deg is not None:
        _robot_state["position"]["heading_deg"] = cmd.heading_deg
    _robot_state["status"] = "idle"
    _robot_state["last_command_at"] = datetime.now(timezone.utc).isoformat()

    return MoveResult(
        accepted=True,
        position=_robot_state["position"],
        status=_robot_state["status"],
        timestamp=_robot_state["last_command_at"],
    )


# CORRECTION : Le serveur est lancé ici avec la variable SERVICE_PORT
if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=SERVICE_PORT, reload=True)