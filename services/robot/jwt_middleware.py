"""
jwt_middleware.py — Sprint 3, Task 3
--------------------------------------
Defense-in-depth JWT validation INSIDE robot-service, in addition to Kong's
"jwt" plugin at the gateway. Rationale: if Kong is ever misconfigured or
bypassed (e.g. a route added without the plugin, or a service reachable
directly on its container port during debugging), the service itself
should not silently trust every request.

This does NOT replace Kong's role: rate limiting, routing, and centralized
policy stay at the gateway. This is a second, independent check — belt and
suspenders, not the primary control.

Requires: pip install python-jose[cryptography] httpx

USAGE in main.py:
    from jwt_middleware import JWTAuthMiddleware
    app.add_middleware(JWTAuthMiddleware, exclude_paths={"/health"})
"""

import os
import time

import httpx
from fastapi import Request
from fastapi.responses import JSONResponse
from jose import jwt, JWTError
from starlette.middleware.base import BaseHTTPMiddleware

KEYCLOAK_INTERNAL_URL = os.environ.get("KEYCLOAK_INTERNAL_URL", "http://keycloak:8080")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "robot-realm")
JWKS_URL = f"{KEYCLOAK_INTERNAL_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/certs"

# Cache JWKS in memory; refresh periodically rather than on every request.
_jwks_cache: dict = {"keys": None, "fetched_at": 0.0}
_JWKS_TTL_SECONDS = 300  # re-fetch at most every 5 minutes


async def _get_jwks() -> dict:
    now = time.monotonic()
    if _jwks_cache["keys"] is None or (now - _jwks_cache["fetched_at"]) > _JWKS_TTL_SECONDS:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(JWKS_URL)
            resp.raise_for_status()
            _jwks_cache["keys"] = resp.json()
            _jwks_cache["fetched_at"] = now
    return _jwks_cache["keys"]


class JWTAuthMiddleware(BaseHTTPMiddleware):
    """
    Validates the Authorization: Bearer <token> header against Keycloak's
    JWKS. Attaches decoded claims to request.state.jwt_claims on success.

    NOTE: this checks signature + expiry only. It does NOT enforce
    role/scope (admin/operator/robot) — that stays a Sprint 4 concern,
    to avoid duplicating RBAC logic in two places that can drift apart.
    """

    def __init__(self, app, exclude_paths: set[str] | None = None):
        super().__init__(app)
        self.exclude_paths = exclude_paths or set()

    async def dispatch(self, request: Request, call_next):
        if request.url.path in self.exclude_paths:
            return await call_next(request)

        auth_header = request.headers.get("Authorization", "")
        if not auth_header.startswith("Bearer "):
            return JSONResponse(status_code=401, content={"detail": "Missing bearer token"})

        token = auth_header.removeprefix("Bearer ").strip()

        try:
            jwks = await _get_jwks()
            unverified_header = jwt.get_unverified_header(token)
            key = next(
                (k for k in jwks["keys"] if k.get("kid") == unverified_header.get("kid")),
                None,
            )
            if key is None:
                # Could mean Keycloak rotated keys since our last JWKS fetch.
                # Force a refresh once before giving up.
                _jwks_cache["keys"] = None
                jwks = await _get_jwks()
                key = next(
                    (k for k in jwks["keys"] if k.get("kid") == unverified_header.get("kid")),
                    None,
                )
            if key is None:
                return JSONResponse(status_code=401, content={"detail": "Unknown signing key"})

            claims = jwt.decode(
                token,
                key,
                algorithms=["RS256"],
                options={"verify_aud": False},  # tighten if you assign an audience per client
            )
            request.state.jwt_claims = claims

        except JWTError as exc:
            return JSONResponse(status_code=401, content={"detail": f"Invalid token: {exc}"})
        except httpx.HTTPError:
            # Keycloak unreachable — fail closed, not open.
            return JSONResponse(status_code=503, content={"detail": "Auth service unavailable"})

        return await call_next(request)