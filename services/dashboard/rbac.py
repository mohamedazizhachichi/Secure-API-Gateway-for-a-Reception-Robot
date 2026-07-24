"""
rbac.py — Sprint 4, Task 1 (FastAPI side)
--------------------------------------------
Enforces the admin/operator/robot permissions matrix from the Cahier des
Charges at the application layer, since Kong's ACL plugin can't distinguish
demo-admin from demo-operator (they share one Kong consumer identity —
see the Sprint 4 message for why).

Depends on jwt_middleware.JWTAuthMiddleware already having run and set
request.state.jwt_claims. If that middleware isn't installed, this fails
closed (403), it does not silently allow access.

USAGE in an endpoint:
    from fastapi import Depends
    from rbac import require_role

    @app.put("/robot/config")
    def update_config(payload: dict, _: None = Depends(require_role("admin"))):
        ...
"""

from fastapi import HTTPException, Request


def get_roles(request: Request) -> set[str]:
    """
    Extracts realm roles from the validated token's claims.
    Keycloak puts realm-level roles under claims["realm_access"]["roles"].
    """
    claims = getattr(request.state, "jwt_claims", None)
    if claims is None:
        # JWTAuthMiddleware didn't run or didn't attach claims — fail closed.
        raise HTTPException(status_code=401, detail="No validated token claims found")

    return set(claims.get("realm_access", {}).get("roles", []))


def require_role(*allowed_roles: str):
    """
    FastAPI dependency factory. Returns a dependency that 403s unless the
    caller's token carries at least one of allowed_roles.

    Per the permissions matrix:
        admin    -> logs: yes, move: yes, modify params: yes
        operator -> logs: yes, move: yes, modify params: NO
        robot    -> logs: NO,  move: yes, modify params: NO
    """
    def _dependency(request: Request):
        roles = get_roles(request)
        if not roles.intersection(allowed_roles):
            raise HTTPException(
                status_code=403,
                detail=f"Requires one of roles: {sorted(allowed_roles)}",
            )
    return _dependency
