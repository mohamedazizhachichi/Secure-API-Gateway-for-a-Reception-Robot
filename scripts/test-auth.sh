#!/usr/bin/env bash
# Charge le fichier .env
set -a
source .env
set +a
# =============================================================================
# test-auth.sh — Sprint 3, Task 2
# Gets a robot JWT via Client Credentials, then verifies:
#   - request without token  -> 401
#   - request with valid token -> 200
#
# USAGE:
#   set -a; source .env; set +a
#   ./test-auth.sh
# =============================================================================
set -euo pipefail

: "${ROBOT_CLIENT_ID:?Missing ROBOT_CLIENT_ID in .env}"
: "${ROBOT_CLIENT_SECRET:?Missing ROBOT_CLIENT_SECRET in .env}"
: "${KEYCLOAK_REALM:?Missing KEYCLOAK_REALM in .env}"
: "${KONG_PROXY_PORT:?Missing KONG_PROXY_PORT in .env}"

KEYCLOAK_TOKEN_URL="http://localhost:8080/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token"
TARGET_URL="http://localhost:${KONG_PROXY_PORT}/robot/state"

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

echo "== Step 1: request a token via Client Credentials (robot identity) =="
TOKEN_RESPONSE=$(curl -sS -X POST "${KEYCLOAK_TOKEN_URL}" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${ROBOT_CLIENT_ID}" \
  --data-urlencode "client_secret=${ROBOT_CLIENT_SECRET}")

# Extract access_token without requiring jq (falls back to python3 if jq absent)
if command -v jq > /dev/null 2>&1; then
  ACCESS_TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access_token')
else
  ACCESS_TOKEN=$(echo "${TOKEN_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")
fi

if [[ -z "${ACCESS_TOKEN}" || "${ACCESS_TOKEN}" == "null" ]]; then
  echo "  Could not obtain a token. Raw response from Keycloak:"
  echo "  ${TOKEN_RESPONSE}"
  exit 1
fi
echo "  Token obtained (truncated): ${ACCESS_TOKEN:0:40}..."

echo ""
echo "== Step 2: request WITHOUT token (expect 401) =="
STATUS_NO_TOKEN=$(curl -sS -o /dev/null -w "%{http_code}" "${TARGET_URL}")
check "No token" "401" "${STATUS_NO_TOKEN}"

echo ""
echo "== Step 3: request WITH valid token (expect 200) =="
STATUS_WITH_TOKEN=$(curl -sS -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${TARGET_URL}")
check "Valid token" "200" "${STATUS_WITH_TOKEN}"

echo ""
echo "== Step 4: request WITH garbage token (expect 401, sanity check) =="
STATUS_BAD_TOKEN=$(curl -sS -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer this.is.not.a.valid.jwt" \
  "${TARGET_URL}")
check "Garbage token" "401" "${STATUS_BAD_TOKEN}"

echo ""
echo "== Results: ${pass} passed, ${fail} failed =="
[[ "${fail}" -eq 0 ]]
