#!/bin/sh
set -eu
. "$(dirname "$0")/registry-auth.sh"
sysop_login
REGISTRY_URL=${SERVICE_REGISTRY_URL:-https://127.0.0.1:8443}
response=$(curl -fsS $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' \
  --data '{"serviceDefinitionNames":["monitoring"]}' "$REGISTRY_URL/serviceregistry/mgmt/service-instances/query")
echo "$response" | jq -r '.entries[]?.instanceId' | while IFS= read -r instance; do
  encoded=$(jq -rn --arg value "$instance" '$value|@uri')
  curl -fsS -X DELETE $SYSOP_TLS -H "$SYSOP_AUTH" \
    "$REGISTRY_URL/serviceregistry/mgmt/service-instances?serviceInstances=$encoded" >/dev/null
  echo "Removed legacy service instance $instance"
done
