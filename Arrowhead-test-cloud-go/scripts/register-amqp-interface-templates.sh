#!/bin/sh
# Creates the interface templates generic_amqp and generic_amqps of the sysMonitor services in the ServiceRegistry
# (the released ServiceRegistry database knows only HTTP and MQTT templates). Idempotent.
set -eu
cd "$(dirname "$0")/.."
. scripts/registry-auth.sh
sysop_login
_registry_port=$(sed -n 's/^SERVICEREGISTRY_PORT=//p' .env 2>/dev/null | tail -n 1)
REGISTRY_URL=${SERVICE_REGISTRY_URL:-https://127.0.0.1:${_registry_port:-8443}}
existing=$(curl -fsS $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' \
  --data '{"templateNames":["generic_amqp","generic_amqps"]}' "$REGISTRY_URL/serviceregistry/mgmt/interface-templates/query" \
  | jq -r '.entries[]?.name')
for template in generic_amqp generic_amqps; do
  if echo "$existing" | grep -qx "$template"; then
    echo "Interface template $template exists"
    continue
  fi
  protocol=${template#generic_}
  jq -n --arg name "$template" --arg protocol "$protocol" '{interfaceTemplates: [{name: $name, protocol: $protocol, propertyRequirements: [
      {name: "accessAddresses", mandatory: true, validator: "NOT_EMPTY_ADDRESS_LIST", validatorParams: []},
      {name: "accessPort", mandatory: true, validator: "PORT", validatorParams: []},
      {name: "exchange", mandatory: true, validator: null, validatorParams: []},
      {name: "baseRoutingKey", mandatory: true, validator: null, validatorParams: []},
      {name: "operations", mandatory: true, validator: "NOT_EMPTY_STRING_SET", validatorParams: ["OPERATION"]}]}]}' \
    | curl -fsS $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' --data @- \
        "$REGISTRY_URL/serviceregistry/mgmt/interface-templates" >/dev/null
  echo "Created interface template $template"
done
