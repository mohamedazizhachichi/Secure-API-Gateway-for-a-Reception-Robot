#!/usr/bin/env bash
# =============================================================================
# test-rbac.sh — Sprint 4, Task 2
#
# IMPORTANT CAVEAT: dashboard-app is configured for Authorization Code flow
# (browser login), which curl can't drive non-interactively. To automate
# token retrieval for demo-admin/demo-operator, this script creates a
# SEPARATE, test-only Keycloak client ("test-cli") with Direct Access
# Grants (Resource Owner Password Credentials) enabled.
#
# ROPC is discouraged by OAuth2 best practice for real apps (it exposes
# user passwords to the client) — that's exactly why dashboard-app doesn't
# use it. test-cli exists ONLY so this test script can run unattended; it
# is not part of the production auth flow and should not be presented as
# such in your rapport de stage. Delete it before any demo to an outside
# evaluator if you want to keep the security story clean, or keep it but
# document clearly why it exists.
#
# USAGE:
#   set -a; source .env; set +a
#   ./test-rbac.sh
# =============================================================================
set -euo pipefail

: "${ROBOT_CLIENT_ID:?Missing ROBOT_CLIENT_ID in .env}"
: "${ROBOT_CLIENT_SECRET:?Missing ROBOT_CLIENT_SECRET in .env}"
: "${KEYCLOAK_REALM:?Missing KEYCLOAK_REALM in .env}"
: "${KEYCLOAK_ADMIN:?Missing KEYCLOAK_ADMIN in .env}"
: "${KEYCLOAK_ADMIN_PASSWORD:?Missing KEYCLOAK_ADMIN_PASSWORD in .env}"
: "${DEMO_ADMIN_PASSWORD:?Missing DEMO_ADMIN_PASSWORD in .env}"
: "${DEMO_OPERATOR_PASSWORD:?Missing DEMO_OPERATOR_PASSWORD in .env}"
: "${KONG_PROXY_PORT:?Missing KONG_PROXY_PORT in .env}"

KEYCLOAK_BASE="http://localhost:8080"
TOKEN_URL="${KEYCLOAK_BASE}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token"
ADMIN_API="${KEYCLOAK_BASE}/admin/realms/${KEYCLOAK_REALM}"

pass=0
fail=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  [PASS] ${label}: expected ${expected}, got ${actual}"
    pass=$((pass + 1))
  else
    echo "  [FAIL] ${label}: expected ${expected}, got ${actual}"
    fail=$((fail + 1))
  fi
}

json_get() {
  # $1 = json string, $2 = python expression on `d`
  python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))" "$1" "$2"
}

# -----------------------------------------------------------------------
# 0. Bootstrap: get a Keycloak master-realm admin token, then ensure
#    test-cli exists with direct grants enabled, and that demo users
#    don't have a pending forced password-reset (which would block ROPC).
# -----------------------------------------------------------------------
echo "== Bootstrap: preparing test-only Keycloak client 'test-cli' =="

ADMIN_TOKEN_RESPONSE=$(curl -sS -X POST "${KEYCLOAK_BASE}/realms/master/protocol/openid-connect/token" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=admin-cli" \
  --data-urlencode "username=${KEYCLOAK_ADMIN}" \
  --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}")
ADMIN_TOKEN=$(json_get "${ADMIN_TOKEN_RESPONSE}" "d.get('access_token','')")

if [[ -z "${ADMIN_TOKEN}" ]]; then
  echo "  Could not get a Keycloak admin token. Response: ${ADMIN_TOKEN_RESPONSE}"
  exit 1
fi

# Does test-cli already exist?
EXISTING=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${ADMIN_API}/clients?clientId=test-cli")
EXISTING_COUNT=$(json_get "${EXISTING}" "len(d)")

if [[ "${EXISTING_COUNT}" == "0" ]]; then
  echo "  Creating test-cli (public client, direct access grants enabled)..."
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
      "description": "TEST ONLY: enables curl-based RBAC testing via ROPC. Not part of production auth flow."
    }' > /dev/null
else
  echo "  test-cli already exists, reusing it."
fi

# Clear any forced "update password" requirement on demo users so ROPC
# doesn't get blocked by a pending required action.
for username in demo-admin demo-operator; do
  USER_JSON=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${ADMIN_API}/users?username=${username}&exact=true")
  USER_ID=$(json_get "${USER_JSON}" "d[0]['id'] if d else ''")
  if [[ -z "${USER_ID}" ]]; then
    echo "  WARNING: user ${username} not found in realm — skipping."
    continue
  fi
  curl -sS -X PUT "${ADMIN_API}/users/${USER_ID}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"requiredActions": []}' > /dev/null
  echo "  Cleared pending required actions for ${username}."
done

# -----------------------------------------------------------------------
# 1. Get tokens for each identity
# -----------------------------------------------------------------------
echo ""
echo "== Fetching tokens =="

get_user_token() {
  local username="$1" password="$2"
  curl -sS -X POST "${TOKEN_URL}" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=test-cli" \
    --data-urlencode "username=${username}" \
    --data-urlencode "password=${password}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))"
}

ROBOT_TOKEN=$(curl -sS -X POST "${TOKEN_URL}" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${ROBOT_CLIENT_ID}" \
  --data-urlencode "client_secret=${ROBOT_CLIENT_SECRET}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")

ADMIN_TOKEN_USER=$(get_user_token "demo-admin" "${DEMO_ADMIN_PASSWORD}")
OPERATOR_TOKEN=$(get_user_token "demo-operator" "${DEMO_OPERATOR_PASSWORD}")

for pair in "robot:${ROBOT_TOKEN}" "admin:${ADMIN_TOKEN_USER}" "operator:${OPERATOR_TOKEN}"; do
  name="${pair%%:*}"
  tok="${pair#*:}"
  if [[ -z "${tok}" || "${tok}" == "null" ]]; then
    echo "  Could not obtain a token for ${name}. Aborting."
    exit 1
  fi
  echo "  ${name} token OK (${tok:0:30}...)"
done

# -----------------------------------------------------------------------
# 2. Access checks
# -----------------------------------------------------------------------
BASE="http://localhost:${KONG_PROXY_PORT}"

req_status() {
  local token="$1" method="$2" path="$3" body="${4:-}"
  if [[ -n "${body}" ]]; then
    curl -sS -o /dev/null -w "%{http_code}" -X "${method}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "${body}" \
      "${BASE}${path}"
  else
    curl -sS -o /dev/null -w "%{http_code}" -X "${method}" \
      -H "Authorization: Bearer ${token}" \
      "${BASE}${path}"
  fi
}

MOVE_BODY='{"dx": 0.5, "dy": 0.0}'
CONFIG_BODY='{"max_speed": 1.0, "safety_zone_radius_m": 0.5}'

echo ""
echo "== Authorization checks =="

# admin: full access, including the config relay (admin-only per matrix)
check "admin -> GET /dashboard/logs"          "200" "$(req_status "${ADMIN_TOKEN_USER}" GET /dashboard/logs)"
check "admin -> POST /dashboard/robot/move"   "200" "$(req_status "${ADMIN_TOKEN_USER}" POST /dashboard/robot/move "${MOVE_BODY}")"
check "admin -> POST /dashboard/robot/config"  "200" "$(req_status "${ADMIN_TOKEN_USER}" POST /dashboard/robot/config "${CONFIG_BODY}")"

# operator: logs + move, but not admin-only config
# NOTE: config is tested via /dashboard/robot/config (the relay), not
# /robot/config directly — the latter is blocked by Kong's ACL (group
# 'robot' only) before it would even reach a FastAPI role check, for
# EVERY human caller including admin. Testing it here would give a false
# "pass" for the wrong reason.
check "operator -> GET /dashboard/logs"        "200" "$(req_status "${OPERATOR_TOKEN}" GET /dashboard/logs)"
check "operator -> POST /dashboard/robot/move" "200" "$(req_status "${OPERATOR_TOKEN}" POST /dashboard/robot/move "${MOVE_BODY}")"
check "operator -> POST /dashboard/robot/config (should be denied)" "403" "$(req_status "${OPERATOR_TOKEN}" POST /dashboard/robot/config "${CONFIG_BODY}")"

# robot: move + state via its own Kong route, but not logs, and not config
check "robot -> POST /robot/move"  "200" "$(req_status "${ROBOT_TOKEN}" POST /robot/move "${MOVE_BODY}")"
check "robot -> GET /robot/state"  "200" "$(req_status "${ROBOT_TOKEN}" GET /robot/state)"
check "robot -> GET /dashboard/logs (should be denied)" "403" "$(req_status "${ROBOT_TOKEN}" GET /dashboard/logs)"
check "robot -> POST /robot/config (should be denied)" "403" "$(req_status "${ROBOT_TOKEN}" POST /robot/config "${CONFIG_BODY}")"

# unauthenticated / no role
check "no token -> GET /dashboard/logs" "401" "$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/dashboard/logs")"

echo ""
echo "== Results: ${pass} passed, ${fail} failed =="
[[ "${fail}" -eq 0 ]]
