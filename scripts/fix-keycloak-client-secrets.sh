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

  echo "    Mot de passe fixé pour '${username}' (UUID: ${USER_ID}, temporary=false)"
}

: "${DEMO_ADMIN_PASSWORD:?Missing DEMO_ADMIN_PASSWORD in .env}"
: "${DEMO_OPERATOR_PASSWORD:?Missing DEMO_OPERATOR_PASSWORD in .env}"

set_user_password "demo-admin" "${DEMO_ADMIN_PASSWORD}"
set_user_password "demo-operator" "${DEMO_OPERATOR_PASSWORD}"
# =============================================================================
# 5. Créer le client test-cli pour les tests RBAC (Sprint 4)
# =============================================================================
echo "--- Création du client 'test-cli' pour les tests RBAC ---"

CLIENT_EXISTS=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${ADMIN_API}/clients?clientId=test-cli" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))")

if [ "$CLIENT_EXISTS" -eq "0" ]; then
  echo "  Création du client test-cli..."
  curl -sS -X POST "${ADMIN_API}/clients" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "clientId": "test-cli",
      "enabled": true,
      "publicClient": true,
      "directAccessGrantsEnabled": true,
      "protocol": "openid-connect",
      "standardFlowEnabled": false,
      "implicitFlowEnabled": false,
      "serviceAccountsEnabled": false,
      "description": "TEST ONLY: enables curl-based RBAC testing via ROPC. Not part of production auth flow."
    }'
  echo "  test-cli client créé"
else
  echo "  test-cli client existe déjà"
fi
echo ""
echo "===== DEBUG : Configuration du client test-cli ====="

CLIENT_UUID=$(curl -sS \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${ADMIN_API}/clients?clientId=test-cli" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")

echo "Client UUID: ${CLIENT_UUID}"

curl -sS \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${ADMIN_API}/clients/${CLIENT_UUID}" \
  | python3 -m json.tool
# =============================================================================
# 6. Créer les utilisateurs demo-admin et demo-operator s'ils n'existent pas
# =============================================================================
echo "--- Création des utilisateurs demo-admin et demo-operator ---"

create_user() {
  local username="$1" password="$2" email="$3"
  
  # Vérifier si l'utilisateur existe déjà
  USER_ID=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${ADMIN_API}/users?username=${username}&exact=true" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")
  
  if [[ -z "${USER_ID}" ]]; then
    echo "  Création de l'utilisateur ${username}..."
    # Créer l'utilisateur
    USER_ID=$(curl -sS -X POST "${ADMIN_API}/users" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{
        \"username\": \"${username}\",
        \"email\": \"${email}\",
        \"emailVerified\": true,
        \"enabled\": true,
        \"firstName\": \"${username}\",
        \"lastName\": \"User\"
      }" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id', ''))")
    
    if [[ -n "${USER_ID}" ]]; then
      echo "  Utilisateur ${username} créé avec ID ${USER_ID}"
      
      # Définir le mot de passe
      curl -sS -X PUT "${ADMIN_API}/users/${USER_ID}/reset-password" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"type\": \"password\", \"value\": \"${password}\", \"temporary\": false}" > /dev/null
      echo "  Mot de passe défini pour ${username}"
      
      # Assigner le rôle admin si c'est demo-admin
      if [[ "${username}" == "demo-admin" ]]; then
        ROLE_ID=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
          "${ADMIN_API}/roles" \
          | python3 -c "import sys,json; d=json.load(sys.stdin); print([r['id'] for r in d if r['name']=='admin'][0] if [r for r in d if r['name']=='admin'] else '')")
        if [[ -n "${ROLE_ID}" ]]; then
          curl -sS -X POST "${ADMIN_API}/users/${USER_ID}/role-mappings/realm" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "[{\"id\": \"${ROLE_ID}\", \"name\": \"admin\"}]" > /dev/null
          echo "  Rôle admin assigné à ${username}"
        fi
      fi
      
      # Assigner le rôle operator si c'est demo-operator
      if [[ "${username}" == "demo-operator" ]]; then
        ROLE_ID=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
          "${ADMIN_API}/roles" \
          | python3 -c "import sys,json; d=json.load(sys.stdin); print([r['id'] for r in d if r['name']=='operator'][0] if [r for r in d if r['name']=='operator'] else '')")
        if [[ -n "${ROLE_ID}" ]]; then
          curl -sS -X POST "${ADMIN_API}/users/${USER_ID}/role-mappings/realm" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "[{\"id\": \"${ROLE_ID}\", \"name\": \"operator\"}]" > /dev/null
          echo "  Rôle operator assigné à ${username}"
        fi
      fi
    else
      echo "  ERREUR: Impossible de créer l'utilisateur ${username}"
    fi
  else
    echo "  Utilisateur ${username} existe déjà (ID: ${USER_ID})"
  fi
}

create_user "demo-admin" "${DEMO_ADMIN_PASSWORD}" "demo-admin@example.local"
create_user "demo-operator" "${DEMO_OPERATOR_PASSWORD}" "demo-operator@example.local"

# Ajouter après la création des utilisateurs
echo "--- Vérification des utilisateurs ---"
for username in demo-admin demo-operator; do
  USER_ID=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${ADMIN_API}/users?username=${username}&exact=true" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")
  
  if [[ -n "${USER_ID}" ]]; then
    echo "  Utilisateur ${username}: ID=${USER_ID}"
    # Vérifier l'état de l'utilisateur
    USER_INFO=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      "${ADMIN_API}/users/${USER_ID}" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print('emailVerified=' + str(d.get('emailVerified', False)) + ', enabled=' + str(d.get('enabled', False)) + ', requiredActions=' + str(d.get('requiredActions', [])))")
    echo "    ${USER_INFO}"
echo ""
echo "===== DEBUG USER JSON ${username} ====="
curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" "${ADMIN_API}/users/${USER_ID}" | python3 -m json.tool
echo "===== END DEBUG USER JSON ====="
echo "===== DEBUG CREDENTIALS ${username} ====="
curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" "${ADMIN_API}/users/${USER_ID}/credentials" | python3 -m json.tool
echo "===== END DEBUG CREDENTIALS ====="
echo "===== DEBUG PASSWORD CHECK ====="

for username in demo-admin demo-operator
do

USER_ID=$(curl -sS \
-H "Authorization: Bearer ${ADMIN_TOKEN}" \
"${ADMIN_API}/users?username=${username}" \
| python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["id"])')


curl -sS \
-H "Authorization: Bearer ${ADMIN_TOKEN}" \
"${ADMIN_API}/users/${USER_ID}/credentials" \
| python3 -m json.tool

done

echo "===== END DEBUG PASSWORD CHECK ====="

  fi
done
# =============================================================================
# 6. Forcer emailVerified et supprimer les actions en attente
# =============================================================================
echo "--- Forcer emailVerified et supprimer les actions en attente ---"

for username in demo-admin demo-operator; do
  USER_ID=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${ADMIN_API}/users?username=${username}&exact=true" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")
  
  if [[ -n "${USER_ID}" ]]; then
    # Mettre à jour l'utilisateur avec emailVerified=true et pas d'actions
    curl -sS -X PUT "${ADMIN_API}/users/${USER_ID}" \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"emailVerified": true, "requiredActions": []}' > /dev/null
    echo "  ${username} mis à jour (emailVerified=true, requiredActions=[])"
  else
    echo "  Utilisateur ${username} non trouvé"
  fi
done
echo ""
echo ""
echo "===== DEBUG AFTER UPDATE ====="

for username in demo-admin demo-operator
do
  USER_ID=$(curl -sS \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${ADMIN_API}/users?username=${username}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["id"])')

  echo "DEBUG USER ${username} ID=${USER_ID}"

  curl -sS \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${ADMIN_API}/users/${USER_ID}" \
  | python3 -m json.tool

done

echo "===== END DEBUG AFTER UPDATE ====="
echo "===== TEST LOGIN demo-admin ====="

curl -v -X POST \
"${KEYCLOAK_BASE}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
--data-urlencode "grant_type=password" \
--data-urlencode "client_id=test-cli" \
--data-urlencode "username=demo-admin" \
--data-urlencode "password=${DEMO_ADMIN_PASSWORD}"

echo ""
echo "===== FIN TEST LOGIN demo-admin ====="
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
