#!/usr/bin/env bash
# =============================================================================
# setup-kong.sh — VERSION CORRIGÉE (intègre le fix azp dès le départ)
#
# Remplace l'ancienne version qui utilisait key_claim_name=iss par défaut,
# ce qui causait une collision : iss est une valeur de REALM Keycloak,
# partagée par tous les clients, donc deux consumers ne pouvaient jamais
# être enregistrés correctement en même temps (voir le débogage RBAC).
#
# Cette version utilise directement key_claim_name=azp (= client_id du
# token, unique par client) — donc pas besoin de lancer un script de
# correctif séparé après coup, y compris sur un environnement CI 100% frais.
#
# USAGE:
#   set -a; source .env; set +a
#   ./setup-kong.sh
# =============================================================================
set -euo pipefail

: "${KONG_ADMIN_PORT:?Missing KONG_ADMIN_PORT in .env}"
: "${REDIS_PASSWORD:?Missing REDIS_PASSWORD in .env}"
: "${KEYCLOAK_REALM:?Missing KEYCLOAK_REALM in .env}"

KONG_ADMIN_URL="http://127.0.0.1:${KONG_ADMIN_PORT}"
ROBOT_SERVICE_URL="http://robot-service:8002"
DASHBOARD_SERVICE_URL="http://dashboard-service:8003"

echo "== Kong Admin API: ${KONG_ADMIN_URL} =="

setup_service() {
  local name="$1" upstream_url="$2" route_path="$3"
  echo "--- Configuring ${name} -> ${upstream_url}${route_path} ---"

  curl -sS -X PUT "${KONG_ADMIN_URL}/services/${name}" \
    --data "url=${upstream_url}" > /dev/null

  curl -sS -X PUT "${KONG_ADMIN_URL}/routes/${name}-route" \
    --data "service.name=${name}" \
    --data "paths[]=${route_path}" \
    --data "strip_path=false" > /dev/null

  # jwt plugin, keyed on 'azp' (client_id) from the start — NOT 'iss'.
  curl -sS -X POST "${KONG_ADMIN_URL}/routes/${name}-route/plugins" \
    --data "name=jwt" \
    --data "config.key_claim_name=azp" > /dev/null

  echo "    Service, route, jwt (azp) done for ${name}."
}

setup_service "robot-service" "${ROBOT_SERVICE_URL}" "/robot"
setup_service "dashboard-service" "${DASHBOARD_SERVICE_URL}" "/dashboard"

echo "--- Fetching Keycloak's signing public key (JWKS) ---"
JWKS_JSON=$(curl -sS "http://localhost:8080/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs")

PUBLIC_KEY_PEM=$(python3 - "$JWKS_JSON" <<'PYEOF'
import sys, json, base64
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization

jwks = json.loads(sys.argv[1])
key = next(k for k in jwks["keys"] if k.get("use") == "sig" and k["kty"] == "RSA")

def b64url_to_int(s: str) -> int:
    padded = s + "=" * (-len(s) % 4)
    return int.from_bytes(base64.urlsafe_b64decode(padded), "big")

pub = rsa.RSAPublicNumbers(b64url_to_int(key["e"]), b64url_to_int(key["n"])).public_key()
pem = pub.public_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PublicFormat.SubjectPublicKeyInfo,
)
print(pem.decode())
PYEOF
)

echo "--- Registering consumers, keyed on client_id (azp) ---"

curl -sS -X PUT "${KONG_ADMIN_URL}/consumers/robot-service-consumer" > /dev/null
curl -sS -X POST "${KONG_ADMIN_URL}/consumers/robot-service-consumer/jwt" \
  --data "algorithm=RS256" \
  --data "key=robot-service" \
  --data-urlencode "rsa_public_key=${PUBLIC_KEY_PEM}" > /dev/null
echo "    robot-service-consumer: key=robot-service"

curl -sS -X PUT "${KONG_ADMIN_URL}/consumers/dashboard-app-consumer" > /dev/null
curl -sS -X POST "${KONG_ADMIN_URL}/consumers/dashboard-app-consumer/jwt" \
  --data "algorithm=RS256" \
  --data "key=dashboard-app" \
  --data-urlencode "rsa_public_key=${PUBLIC_KEY_PEM}" > /dev/null
echo "    dashboard-app-consumer: key=dashboard-app"

# Couvre les tokens du client de test ROPC (azp="test-cli"), utilisé par
# test-rbac.sh pour simuler admin/operator sans navigateur.
curl -sS -X POST "${KONG_ADMIN_URL}/consumers/dashboard-app-consumer/jwt" \
  --data "algorithm=RS256" \
  --data "key=test-cli" \
  --data-urlencode "rsa_public_key=${PUBLIC_KEY_PEM}" > /dev/null
echo "    dashboard-app-consumer: key=test-cli (couvre test-rbac.sh)"

echo ""
echo "== Kong (auth) configuration complete — prêt pour setup-rbac.sh =="
