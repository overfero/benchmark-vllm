#!/usr/bin/env bash
# Run once after `docker compose up -d` (give Keycloak ~30s to finish
# starting first). Creates the same realm/client/demo-user this session
# already proved working against the K8s version's Keycloak, via the same
# Admin REST API calls - just pointed at the Compose instance instead.
#
# Prints the chat-dashboard client secret at the end - put that value into
# .env's CHAT_DASHBOARD_CLIENT_SECRET, then `docker compose up -d oauth2-proxy`
# to pick it up.
#
# Usage: ./setup_keycloak_realm.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

KC_URL="http://localhost:8081"
KC_ADMIN_USER="${KEYCLOAK_ADMIN_USERNAME:-admin}"
KC_ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:?set KEYCLOAK_ADMIN_PASSWORD (same value as in .env)}"

echo "waiting for Keycloak..."
for i in $(seq 1 30); do
  curl -sf -o /dev/null "$KC_URL/realms/master" && break
  sleep 2
done

TOKEN=$(curl -s -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=$KC_ADMIN_USER" -d "password=$KC_ADMIN_PASS" -d "grant_type=password" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

echo "creating realm 'chat-ui'..."
curl -s -o /dev/null -w "  HTTP %{http_code}\n" -X POST "$KC_URL/admin/realms" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"realm":"chat-ui","enabled":true}'

echo "creating client 'chat-dashboard'..."
curl -s -o /dev/null -w "  HTTP %{http_code}\n" -X POST "$KC_URL/admin/realms/chat-ui/clients" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{
    "clientId": "chat-dashboard",
    "enabled": true,
    "publicClient": false,
    "protocol": "openid-connect",
    "redirectUris": ["http://localhost:4180/oauth2/callback"],
    "standardFlowEnabled": true,
    "directAccessGrantsEnabled": false
  }'

CLIENT_UUID=$(curl -s "$KC_URL/admin/realms/chat-ui/clients?clientId=chat-dashboard" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])")

SECRET=$(curl -s "$KC_URL/admin/realms/chat-ui/clients/$CLIENT_UUID/client-secret" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])")

echo "creating demo user (username: demo)..."
read -r -s -p "set a password for the demo user: " DEMO_PASS
echo
curl -s -o /dev/null -w "  HTTP %{http_code}\n" -X POST "$KC_URL/admin/realms/chat-ui/users" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"username\":\"demo\",\"enabled\":true,\"credentials\":[{\"type\":\"password\",\"value\":\"$DEMO_PASS\",\"temporary\":false}]}"

echo
echo "=== done ==="
echo "put this in .env as CHAT_DASHBOARD_CLIENT_SECRET:"
echo "$SECRET"
echo "then: docker compose up -d oauth2-proxy"
