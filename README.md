# Secure API Gateway — Sprint 3 Prep Skeleton

Simulation-only. No physical robot at any point (Cahier des Charges V3, §1/§3).

## Quick start

```bash
cp .env.example .env
# edit .env and set real values for every change_me_* placeholder
docker-compose up -d --build
```

- Kong proxy: `http://localhost:8000`
- Kong Admin API: `http://127.0.0.1:8444` (bound to localhost only, not exposed to the network)
- Keycloak: `http://localhost:8080`
- Robot service (direct, for dev only — not the intended entry point): `http://localhost:8001`
- Dashboard service (direct, for dev only): `http://localhost:8002`

## What's included (Task 1)

- Kong + its own Postgres, with a one-shot migrations container
- Keycloak + its own Postgres (deliberately separate DB from Kong's)
- Redis, password-protected, reserved for Kong's rate-limiting plugin (Sprint 4)
- Two FastAPI skeletons: `robot-service` (simulated robot, EF-06) and `dashboard-service`
- Health checks on every service
- All config externalized to `.env` (gitignored); `.env.example` is the checked-in template

## What's included (Task 2)

`keycloak/robot-realm.json` — realm export with:
- Realm `robot-realm`
- Roles: `admin`, `operator`, `robot`
- Client `robot-service`: Client Credentials only (`serviceAccountsEnabled: true`, `standardFlowEnabled: false`), access token lifespan 300s
- Client `dashboard-app`: Authorization Code flow, access token lifespan 900s
- Two demo human users (temporary passwords) for manual testing

## Known gaps to close in Sprint 3 (flagging honestly rather than pretending this is done)

1. **Kong ↔ Keycloak wiring is not yet configured.** This compose file stands both up but doesn't yet install the Kong `openid-connect` plugin, routes, or services pointing at `robot-service`/`dashboard-service`. That's the core Sprint 3 task — this skeleton is the foundation for it.
2. **Service-account role mapping for `robot-service`.** Keycloak's realm-import JSON does not reliably attach a realm role to a client's *service account* user across versions. After first `docker-compose up`, verify in the Admin Console (Clients → robot-service → Service Account Roles) that the `robot` role is actually assigned — don't assume the JSON import did it. If it didn't, either assign it manually or automate it with `kcadm.sh`/the Admin REST API as a post-start step; worth documenting whichever you pick.
3. **`${env.VAR}` secret placeholders in the realm JSON** rely on Keycloak resolving environment variables at import time. This is generally supported but is worth confirming against your exact Keycloak 25.0 behavior on first run — if secrets come through literally as the string `${env.ROBOT_CLIENT_SECRET}` instead of the real value, you'll need to set them manually via Admin Console or switch to Keycloak's vault provider syntax instead.
4. **No RBAC/scope enforcement yet at Kong or in the FastAPI services** — both services currently trust whatever reaches them. That's expected for a skeleton; Sprint 4 is where the permissions matrix (admin/operator/robot) actually gets enforced.
5. **Replay-attack risk (accepted per Cahier des Charges V3 §8/§10):** the 5-minute JWT lifetime bounds but does not eliminate replay within that window. Documented in the Cahier des Charges as an accepted risk for the simulated context — worth restating in the Sprint 5 security test report rather than treated as solved.

## Directory layout

```
.
├── docker-compose.yml
├── .env.example
├── keycloak/
│   └── robot-realm.json
├── services/
│   ├── robot/       (FastAPI, EF-06 simulated robot)
│   └── dashboard/    (FastAPI, dashboard backend)
```
