#!/usr/bin/env bash
# =============================================================================
# fix-keycloak-client-secrets.sh
#
# Contourne un problème confirmé : les placeholders ${env.X} dans
# keycloak/robot-realm.json ne sont pas résolus de façon fiable par
# Keycloak au moment de l'import (--import-realm). Plutôt que de dépendre
# de ce mécanisme, ce script force explicitement les secrets clients via
# l'API Admin REST de Keycloak, juste après son démarrage.
#
# USAGE:
#   set -a; source .env; set +a
#   ./fix-keycloak-client-secrets.sh
# =============================================================================
set -euo pipefail

: "${KEYCLOAK_ADMIN:?Missing KEYCLOAK_ADMIN in .env}"
: "${KEYCLOAK_ADMIN_PASSWORD:?Missing KEYCLOAK_ADMIN_PASSWORD in .env}"
: "${KEYCLOAK_REALM:?Missing KEYCLOAK_REALM in .env}"
: "${ROBOT_CLIENT_SECRET:?Missing ROBOT_CLIENT_SECRET in .env}"
: "${DASHBOARD_CLIENT_SECRET:?Missing DASHBOARD_CLIENT_SECRET in .env}"

KEYCLOAK_BASE="http://localhost:8080"
ADMIN_API="${KEYCLOAK_BASE}/admin/realms/${KEYCLOAK_REALM}"

echo "== Obtention d'un token admin Keycloak =="
ADMIN_TOKEN=$(curl -sS -X POST "${KEYCLOAK_BASE}/realms/master/protocol/openid-connect/token" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=admin-cli" \
  --data-urlencode "username=${KEYCLOAK_ADMIN}" \
  --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")

if [[ -z "${ADMIN_TOKEN}" ]]; then
  echo "  ERREUR: impossible d'obtenir un token admin Keycloak." >&2
  exit 1
fi

set_client_secret() {
  local client_id="$1" secret_value="$2"

  echo "--- Fixation du secret pour le client '${client_id}' ---"

  # 1. Trouver l'UUID interne du client (différent de son clientId lisible)
  CLIENT_UUID=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${ADMIN_API}/clients?clientId=${client_id}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")

  if [[ -z "${CLIENT_UUID}" ]]; then
    echo "  ERREUR: client '${client_id}' introuvable dans le realm ${KEYCLOAK_REALM}." >&2
    exit 1
  fi

  # 2. Récupérer la représentation complète actuelle du client
  CLIENT_JSON=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${ADMIN_API}/clients/${CLIENT_UUID}")

  # 3. Modifier uniquement le champ "secret", garder tout le reste identique
  UPDATED_JSON=$(echo "${CLIENT_JSON}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['secret'] = '${secret_value}'
print(json.dumps(d))
")

  # 4. Renvoyer la représentation complète mise à jour
  curl -sS -X PUT "${ADMIN_API}/clients/${CLIENT_UUID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${UPDATED_JSON}" > /dev/null

  echo "    Secret fixé pour '${client_id}' (UUID: ${CLIENT_UUID})"
}

set_client_secret "robot-service" "${ROBOT_CLIENT_SECRET}"
set_client_secret "dashboard-app" "${DASHBOARD_CLIENT_SECRET}"

echo ""
echo "== Vérification : test immédiat d'obtention d'un token robot =="
TEST_TOKEN=$(curl -sS -X POST "${KEYCLOAK_BASE}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=robot-service" \
  --data-urlencode "client_secret=${ROBOT_CLIENT_SECRET}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")

if [[ -z "${TEST_TOKEN}" ]]; then
  echo "  ERREUR: toujours impossible d'obtenir un token après correction." >&2
  exit 1
fi
echo "  OK — token obtenu avec succès (${TEST_TOKEN:0:30}...)"
