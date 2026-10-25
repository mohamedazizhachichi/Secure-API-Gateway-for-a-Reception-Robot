#!/usr/bin/env bash
# =============================================================================
# setup-rbac.sh — Sprint 4, Task 1
#
# WHAT THIS DOES (and does NOT do — read the caveat below):
#   - Puts robot-service-consumer into an ACL group "robot" and restricts
#     the /robot route to that group. This cleanly separates M2M traffic
#     from human traffic at the gateway.
#   - Applies differentiated, per-consumer rate limiting (robot vs humans).
#
#   It does NOT distinguish demo-admin from demo-operator at the Kong
#   layer — both authenticate as the same Kong consumer (dashboard-app-consumer)
#   because they share Keycloak's realm signing key. That distinction is
#   enforced in FastAPI instead (see services/*/rbac.py). See the message
#   accompanying this script for why.
#
# USAGE:
#   set -a; source .env; set +a
#   ./setup-rbac.sh
# =============================================================================
set -euo pipefail

: "${KONG_ADMIN_PORT:?Missing KONG_ADMIN_PORT in .env}"
KONG_ADMIN_URL="http://127.0.0.1:${KONG_ADMIN_PORT}"

echo "== Kong Admin API: ${KONG_ADMIN_URL} =="

# -----------------------------------------------------------------------
# 1. ACL plugin: enable on both routes (required before groups can be
#    enforced), default-deny anything not explicitly allowed.
# -----------------------------------------------------------------------
echo "--- Enabling ACL plugin on /robot route (allow group: robot) ---"
curl -sS -X POST "${KONG_ADMIN_URL}/routes/robot-service-route/plugins" \
  --data "name=acl" \
  --data "config.allow=robot" \
  > /dev/null

# The /dashboard route accepts any authenticated human (admin or operator);
# fine-grained admin-vs-operator checks happen inside dashboard-service.
echo "--- Enabling ACL plugin on /dashboard route (allow group: humans) ---"
curl -sS -X POST "${KONG_ADMIN_URL}/routes/dashboard-service-route/plugins" \
  --data "name=acl" \
  --data "config.allow=humans" \
  > /dev/null

# -----------------------------------------------------------------------
# 2. Assign ACL groups to existing consumers (created in Sprint 3)
# -----------------------------------------------------------------------
echo "--- Assigning robot-service-consumer to group 'robot' ---"
curl -sS -X POST "${KONG_ADMIN_URL}/consumers/robot-service-consumer/acls" \
  --data "group=robot" \
  > /dev/null

echo "--- Assigning dashboard-app-consumer to group 'humans' ---"
curl -sS -X POST "${KONG_ADMIN_URL}/consumers/dashboard-app-consumer/acls" \
  --data "group=humans" \
  > /dev/null

# -----------------------------------------------------------------------
# 3. Differentiated rate limiting.
#    NOTE: because admin and operator share one Kong consumer, this can
#    only set ONE ceiling for "all humans" (100/min below, matching the
#    admin figure from the spec) — not separate admin=100/operator=X.
#    If you need Kong-level separation for rate limits too, that's the
#    same limitation as ACL and points to option (B) — openid-connect —
#    not a scripting workaround.
# -----------------------------------------------------------------------
echo "--- Removing the flat 5/min route-level rate limit from Sprint 3 ---"
# Find and delete the old route-level rate-limiting plugins so per-consumer
# overrides below aren't fighting a stricter route-level default.
for route in robot-service-route dashboard-service-route; do
  OLD_PLUGIN_ID=$(curl -sS "${KONG_ADMIN_URL}/routes/${route}/plugins" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(next((p['id'] for p in d['data'] if p['name']=='rate-limiting'), ''))")
  if [[ -n "${OLD_PLUGIN_ID}" ]]; then
    curl -sS -X DELETE "${KONG_ADMIN_URL}/routes/${route}/plugins/${OLD_PLUGIN_ID}" > /dev/null
    echo "    Removed old rate-limiting plugin (${OLD_PLUGIN_ID}) from ${route}"
  fi
done

echo "--- Applying per-consumer rate limits ---"
: "${REDIS_PASSWORD:?Missing REDIS_PASSWORD in .env}"

curl -sS -X POST "${KONG_ADMIN_URL}/consumers/robot-service-consumer/plugins" \
  --data "name=rate-limiting" \
  --data "config.minute=10" \
  --data "config.policy=redis" \
  --data "config.redis.host=redis" \
  --data "config.redis.port=6379" \
  --data "config.redis.password=${REDIS_PASSWORD}" \
  --data "config.fault_tolerant=true" \
  > /dev/null
echo "    robot-service-consumer: 10 req/min"

curl -sS -X POST "${KONG_ADMIN_URL}/consumers/dashboard-app-consumer/plugins" \
  --data "name=rate-limiting" \
  --data "config.minute=100" \
  --data "config.policy=redis" \
  --data "config.redis.host=redis" \
  --data "config.redis.port=6379" \
  --data "config.redis.password=${REDIS_PASSWORD}" \
  --data "config.fault_tolerant=true" \
  > /dev/null
echo "    dashboard-app-consumer (all humans): 100 req/min"

echo ""
echo "== RBAC setup complete =="
echo "   Reminder: admin-vs-operator authorization is enforced in FastAPI"
echo "   (services/*/rbac.py), not by Kong ACL. See NOTES.md for why."
