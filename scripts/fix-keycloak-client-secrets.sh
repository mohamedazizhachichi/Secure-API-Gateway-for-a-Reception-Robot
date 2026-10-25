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

# -----------------------------------------------------------------------
# Client de test "test-cli" : nécessaire pour que test-rbac.sh puisse
# obtenir des tokens demo-admin/demo-operator via curl (Direct Access
# Grants / ROPC), sans navigateur. Sur un Keycloak fraîchement importé
# (CI), ce client n'existe pas tant qu'on ne le crée pas explicitement —
# contrairement à un environnement local où il persiste d'une session à
# l'autre une fois créé manuellement.
# -----------------------------------------------------------------------
echo "--- Vérification/création du client de test 'test-cli' ---"

EXISTING=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${ADMIN_API}/clients?clientId=test-cli" \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

if [[ "${EXISTING}" == "0" ]]; then
  curl -sS -X POST "${ADMIN_API}/clients" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "clientId": "test-cli",
      "publicClient": true,
      "directAccessGrantsEnabled": true,
      "standardFlowEnabled": false,
      "serviceAccountsEnabled": false,
      "enabled": true,
      "description": "TEST ONLY: permet a test-rbac.sh de recuperer des jetons via curl. Pas une voie normale d authentification en production."
    }' > /dev/null
  echo "    test-cli créé (public, Direct Access Grants activé)"
else
  echo "    test-cli existe déjà, réutilisé"
fi

set_user_password() {
  local username="$1" password_value="$2"

  echo "--- Fixation du mot de passe pour l'utilisateur '${username}' ---"

  USER_ID=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${ADMIN_API}/users?username=${username}&exact=true" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")

  if [[ -z "${USER_ID}" ]]; then
    echo "  ERREUR: utilisateur '${username}' introuvable dans le realm ${KEYCLOAK_REALM}." >&2
    exit 1
  fi

  curl -sS -X PUT "${ADMIN_API}/users/${USER_ID}/reset-password" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"type\": \"password\", \"value\": \"${password_value}\", \"temporary\": false}" > /dev/null

  # Le changement de mot de passe ne supprime PAS les requiredActions déjà
  # présentes sur le compte (ex: UPDATE_PASSWORD ajouté automatiquement par
  # Keycloak au moment de l'import du realm, à cause de "temporary": true
  # dans keycloak/robot-realm.json). Sans cette étape, Keycloak refuse la
  # connexion avec "Account is not fully set up" même avec le bon mot de
  # passe — les deux mécanismes sont indépendants côté API Keycloak.
  #
  # IMPORTANT : on récupère la représentation COMPLÈTE de l'utilisateur
  # avant de modifier, comme pour set_client_secret — un PUT partiel
  # (juste {"requiredActions": []}) peut être rejeté ou ignoré selon la
  # version de Keycloak, sans erreur visible si on ne vérifie pas.
  USER_JSON=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${ADMIN_API}/users/${USER_ID}")

  UPDATED_USER_JSON=$(echo "${USER_JSON}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['requiredActions'] = []
d['enabled'] = True
print(json.dumps(d))
")

  HTTP_STATUS=$(curl -sS -o /tmp/put_response.json -w "%{http_code}" -X PUT "${ADMIN_API}/users/${USER_ID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${UPDATED_USER_JSON}")

  if [[ "${HTTP_STATUS}" -ge 400 ]]; then
    echo "  ERREUR (${HTTP_STATUS}) lors du nettoyage des requiredActions pour '${username}':" >&2
    cat /tmp/put_response.json >&2
    exit 1
  fi

  # Vérification factuelle : relire l'état réel plutôt que de supposer
  VERIFY_JSON=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${ADMIN_API}/users/${USER_ID}")
  echo "    Vérification post-modification pour '${username}':"
  echo "${VERIFY_JSON}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"      enabled={d.get('enabled')}, emailVerified={d.get('emailVerified')}, requiredActions={d.get('requiredActions')}\")
"

  echo "    Mot de passe fixé pour '${username}' (UUID: ${USER_ID}, temporary=false)"
}

: "${DEMO_ADMIN_PASSWORD:?Missing DEMO_ADMIN_PASSWORD in .env}"
: "${DEMO_OPERATOR_PASSWORD:?Missing DEMO_OPERATOR_PASSWORD in .env}"

set_user_password "demo-admin" "${DEMO_ADMIN_PASSWORD}"
set_user_password "demo-operator" "${DEMO_OPERATOR_PASSWORD}"

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