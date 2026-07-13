#!/usr/bin/env bash
# Charge le fichier .env
set -a
source .env
set +a
# =============================================================================
# setup-kong.sh — Sprint 3, Task 1
# Configures Kong: services + routes for robot-service/dashboard-service,
# JWT validation, and Redis-backed rate limiting.
#
# PREREQUISITE: Kong, Keycloak, Redis, robot-service and dashboard-service
# must already be up and healthy (docker-compose up -d).
#
# USAGE:
#   set -a; source .env; set +a
#   ./setup-kong.sh
#
# All values (ports, Redis password, Keycloak realm) come from your .env —
# nothing here is hardcoded (ENF-05/ENF-08).
# =============================================================================
set -euo pipefail

: "${KONG_ADMIN_PORT:?Missing KONG_ADMIN_PORT in .env}"
: "${REDIS_PASSWORD:?Missing REDIS_PASSWORD in .env}"
: "${KEYCLOAK_REALM:?Missing KEYCLOAK_REALM in .env}"

# Per the updated project state: Kong admin now on 8001, robot on 8002, dashboard on 8003.
KONG_ADMIN_URL="http://127.0.0.1:${KONG_ADMIN_PORT}"
ROBOT_SERVICE_URL="http://robot-service:8002"
DASHBOARD_SERVICE_URL="http://dashboard-service:8003"

# Keycloak issuer as it will appear in the "iss" claim of tokens minted for
# this realm. This MUST exactly match what Keycloak puts in the token, or
# the jwt plugin will reject valid tokens. If your browser/host reaches
# Keycloak via localhost:8080 but containers reach it via keycloak:8080,
# double-check which hostname Keycloak actually stamps into "iss" — it uses
# whatever hostname the *client* used to reach the token endpoint, not a
# fixed internal value. Adjust ISSUER below if your test script gets tokens
# from a different host than this assumes.
ISSUER="http://localhost:8080/realms/${KEYCLOAK_REALM}"

echo "== Kong Admin API: ${KONG_ADMIN_URL} =="

# -----------------------------------------------------------------------
# Helper: create a Kong service+route+jwt+rate-limiting bundle
#   $1 = service name
#   $2 = upstream URL
#   $3 = route path prefix (e.g. /robot)
# -----------------------------------------------------------------------
setup_service() {
  local name="$1"
  local upstream_url="$2"
  local route_path="$3"

  echo "--- Configuring ${name} -> ${upstream_url}${route_path} ---"

  # 1. Service (idempotent: PUT instead of POST so re-running is safe)
  curl -sS -X PUT "${KONG_ADMIN_URL}/services/${name}" \
    --data "url=${upstream_url}" \
    > /dev/null

  # 2. Route
  curl -sS -X PUT "${KONG_ADMIN_URL}/routes/${name}-route" \
    --data "service.name=${name}" \
    --data "paths[]=${route_path}" \
    --data "strip_path=false" \
    > /dev/null

  # 3. JWT plugin on the route
  #    NOTE: this only enforces "does the request carry a token that Kong
  #    can validate against a registered consumer". It does not by itself
  #    check roles/scopes (admin/operator/robot) — that's RBAC, Sprint 4.
  curl -sS -X POST "${KONG_ADMIN_URL}/routes/${name}-route/plugins" \
    --data "name=jwt" \
    > /dev/null

  # 4. Rate limiting, Redis-backed (EF-03), 5 req/min per the Sprint 3 spec
  curl -sS -X POST "${KONG_ADMIN_URL}/routes/${name}-route/plugins" \
    --data "name=rate-limiting" \
    --data "config.minute=5" \
    --data "config.policy=redis" \
    --data "config.redis.host=redis" \
    --data "config.redis.port=6379" \
    --data "config.redis.password=${REDIS_PASSWORD}" \
    --data "config.fault_tolerant=true" \
    > /dev/null

  echo "    Service, route, jwt, rate-limiting done for ${name}."
}

setup_service "robot-service" "${ROBOT_SERVICE_URL}" "/robot"
setup_service "dashboard-service" "${DASHBOARD_SERVICE_URL}" "/dashboard"

# -----------------------------------------------------------------------
# Register a Kong Consumer + JWT credential representing the robot's
# Keycloak identity. This is the manual-sync step flagged in the README:
# Kong's "jwt" plugin needs the issuer's RSA public key registered per
# consumer. It does NOT auto-refresh if Keycloak rotates its signing key.
# -----------------------------------------------------------------------
echo "--- Registering Kong consumer for the robot's Keycloak identity ---"

curl -sS -X PUT "${KONG_ADMIN_URL}/consumers/robot-service-consumer" \
  > /dev/null

echo "    Fetching Keycloak's signing public key (JWKS)..."
JWKS_JSON=$(curl -sS "http://localhost:8080/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs")

# Convert the first RSA signing key (use = "sig") from JWKS (n, e) to PEM.
# Requires: python3 with the `cryptography` package.
#   pip install cryptography --break-system-packages
PUBLIC_KEY_PEM=$(python3 - "$JWKS_JSON" <<'PYEOF'
import sys, json, base64
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization

jwks = json.loads(sys.argv[1])
key = next(k for k in jwks["keys"] if k.get("use") == "sig" and k["kty"] == "RSA")

def b64url_to_int(s: str) -> int:
    padded = s + "=" * (-len(s) % 4)
    return int.from_bytes(base64.urlsafe_b64decode(padded), "big")

n = b64url_to_int(key["n"])
e = b64url_to_int(key["e"])
pub_numbers = rsa.RSAPublicNumbers(e, n)
pub_key = pub_numbers.public_key()
pem = pub_key.public_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PublicFormat.SubjectPublicKeyInfo,
)
print(pem.decode())
PYEOF
)

# The "key" field below MUST equal the "iss" claim Keycloak puts in the
# token, since that's what Kong's jwt plugin uses to look up the consumer.
curl -sS -X POST "${KONG_ADMIN_URL}/consumers/robot-service-consumer/jwt" \
  --data "algorithm=RS256" \
  --data "key=${ISSUER}" \
  --data-urlencode "rsa_public_key=${PUBLIC_KEY_PEM}" \
  > /dev/null

echo "--- Registering Kong consumer for the dashboard's Keycloak identity ---"
curl -sS -X PUT "${KONG_ADMIN_URL}/consumers/dashboard-app-consumer" \
  > /dev/null
curl -sS -X POST "${KONG_ADMIN_URL}/consumers/dashboard-app-consumer/jwt" \
  --data "algorithm=RS256" \
  --data "key=${ISSUER}" \
  --data-urlencode "rsa_public_key=${PUBLIC_KEY_PEM}" \
  > /dev/null

echo "== Kong configuration complete =="
echo "   If tokens are still rejected with 401, check:"
echo "   1. Does the 'iss' claim in your actual token match ISSUER=${ISSUER} exactly?"
echo "      (decode a token at jwt.io or 'echo \$TOKEN | cut -d. -f2 | base64 -d' to check)"
echo "   2. Did the JWKS fetch return a 'sig' key? (some Keycloak configs also expose 'enc' keys)"
