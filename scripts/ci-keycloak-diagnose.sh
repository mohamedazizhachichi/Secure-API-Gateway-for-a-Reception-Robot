#!/usr/bin/env bash

DEBUG_DIR="ci-debug"
mkdir -p "${DEBUG_DIR}"

REALM="robot-realm"

KCADM="docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh --config /tmp/kcadm.config"

echo "=================================================="
echo " KEYCLOAK CI DIAGNOSTIC"
echo "=================================================="


echo "--- Authentication admin ---"

$KCADM config credentials \
 --server http://localhost:8080 \
 --realm master \
 --user admin \
 --password "${KEYCLOAK_ADMIN_PASSWORD}"


echo "--- Users inspection ---"

for USERNAME in demo-admin demo-operator
do

echo "Checking ${USERNAME}"

$KCADM get users \
-r "${REALM}" \
-q username="${USERNAME}" \
| jq . > "${DEBUG_DIR}/${USERNAME}-user.json"


USER_ID=$(jq -r '.[0].id // empty' \
"${DEBUG_DIR}/${USERNAME}-user.json")


if [ -n "${USER_ID}" ]; then

$KCADM get users/${USER_ID}/role-mappings \
-r "${REALM}" \
| jq . > "${DEBUG_DIR}/${USERNAME}-roles.json"

fi

done



echo "--- Client test-cli ---"

$KCADM get clients \
-r "${REALM}" \
-q clientId=test-cli \
| jq . > "${DEBUG_DIR}/test-cli.json"



echo "--- Password grant tests ---"


test_grant()
{

USER=$1
PASSWORD=$2


RESPONSE=$(curl -s \
-w "\nHTTP_STATUS:%{http_code}" \
-X POST \
"http://localhost:8080/realms/${REALM}/protocol/openid-connect/token" \
-d "grant_type=password" \
-d "client_id=test-cli" \
-d "username=${USER}" \
-d "password=${PASSWORD}")


STATUS=$(echo "$RESPONSE" | grep HTTP_STATUS | cut -d: -f2)

BODY=$(echo "$RESPONSE" | sed '/HTTP_STATUS/d')


echo "$BODY" > "${DEBUG_DIR}/grant-${USER}.json"


echo "${USER}: HTTP ${STATUS}"

}


test_grant demo-admin "${DEMO_ADMIN_PASSWORD}"

test_grant demo-operator "${DEMO_OPERATOR_PASSWORD}"



echo "--- Keycloak logs ---"

docker compose logs --tail=500 keycloak \
> "${DEBUG_DIR}/keycloak.log" 2>&1



echo "Diagnostic finished"

exit 0
