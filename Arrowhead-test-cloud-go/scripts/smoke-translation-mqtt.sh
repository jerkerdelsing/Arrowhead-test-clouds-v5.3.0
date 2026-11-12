#!/bin/sh
# HTTPS <-> MQTT translation bridges of TestTranslation (2026-10-24), consumer SmokeClient (never a running system):
#   A. MQTT consumer -> HTTPS provider with data model translation: SmokeClient orchestrates over MQTT
#      (DynamicServiceOrchestration pull, interfaceTemplateNames generic_mqtts, ALLOW_TRANSLATION, simpleJson output)
#      and calls the generic_mqtts bridge interface; TestTranslation calls the DataManager over HTTPS (senml).
#   B. HTTPS consumer -> MQTT provider: the provider offers generic_https and generic_mqtts, so orchestration would
#      match natively; Sysop builds the bridge for consumer SmokeClient to the provider's generic_mqtts interface only
#      (TranslationManager management discovery/negotiation, as DynamicServiceOrchestration does; the candidate
#      authorization check is off, as the core/bootstrap services have no ConsumerAuthorization policy) and SmokeClient
#      calls the generic_https bridge; TestTranslation sends the MQTT request with its own identity.
#      B1 Go core: DynamicServiceOrchestration serviceOrchestration.pull over MQTT.
#   Further providers (Java Blacklist, Rust TimeManager) when deployed: see sections C and D.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib-secrets.sh
. scripts/registry-auth.sh
CERT_DIR=${CERT_DIR:-security/x509}
MQTT_PORT=$(sed -n 's/^MQTT_TLS_PORT=//p' .env | tail -n 1)
TOOL=go-native-full/host/mqtt-call
mkdir -p go-native-full/host
(cd ../ah5-core-go && go build -trimpath -o "../Arrowhead-test-cloud-go/$TOOL" ./cmd/mqtt-call)
SMK="--cacert $CERT_DIR/ca.crt --cert $CERT_DIR/smoke-client.crt --key $CERT_DIR/smoke-client.key"
TM=https://127.0.0.1:7465 SR=https://127.0.0.1:7443 DM=https://127.0.0.1:7461
fail() { echo "FAIL: $*" >&2; exit 1; }
mq() {  # mqtt-call as SmokeClient
  "$TOOL" -broker "ssl://127.0.0.1:${MQTT_PORT:-8883}" -ca "$CERT_DIR/ca.crt" -cert "$CERT_DIR/smoke-client.crt" -key "$CERT_DIR/smoke-client.key" -system SmokeClient "$@"
}
token=$(curl -fsS $SMK -H 'Content-Type: application/json' \
  --data "{\"systemName\":\"SmokeClient\",\"credentials\":{\"password\":\"$(secret AH_PW_SMK)\"}}" \
  https://127.0.0.1:7444/authentication/identity/login | jq -er '.token')
AUTH="Authorization: Bearer IDENTITY-TOKEN//$token"
smk() { curl -sS $SMK -H "$AUTH" -H 'Content-Type: application/json' "$@"; }
# host origin of a bridge interface published by test-translation
bridge_origin() { printf '%s' "$1" | jq -r '"https://127.0.0.1:" + (if .properties.accessAddresses[0] == "test-translation" then "7466" else (.properties.accessPort|tostring) end) + .properties.basePath'; }

echo "== A. MQTT consumer -> DataManager (HTTPS, senml) as simpleJson"
service=$(smk "$DM/datamanager/data-historian/systems/RandomDataProducer/services" | jq -er '.services[0]')
pull=$(mq -token "$token" -topic arrowhead/serviceorchestration/orchestration/pull -payload '{"serviceRequirement":{"serviceDefinition":"dataHistorian","operations":["get-data"],"interfaceTemplateNames":["generic_mqtts"],"interfacePropertyRequirements":[{"dataModels.get-data.output":{"op":"EQUALS","value":"simpleJson"}}]},"orchestrationFlags":{"ALLOW_TRANSLATION":true,"MATCHMAKING":true}}') \
  || fail "orchestration over MQTT: no response"
result=$(printf '%s' "$pull" | jq -c '.payload.results[0] // empty')
[ -n "$result" ] || fail "no orchestration result: $pull"
intf=$(printf '%s' "$result" | jq -c '.interfaces[0]')
printf '%s' "$intf" | jq -e '.templateName == "generic_mqtts" and .policy == "TRANSLATION_BRIDGE_TOKEN_AUTH"' >/dev/null || fail "not an MQTT bridge: $result"
bridge=$(printf '%s' "$result" | jq -er '.authorizationTokens.TRANSLATION_BRIDGE_TOKEN_AUTH["get-data"].token')
topic=$(printf '%s' "$intf" | jq -r '.properties.baseTopic')get-data
echo "   bridge $bridge: $topic"
code=0; mq -auth TRANSLATION-BRIDGE-TOKEN -token not-the-bridge -topic "$topic" -params "systemName=RandomDataProducer,serviceName=$service,count=3" -timeout 3s >/dev/null 2>&1 || code=$?
[ "$code" = 2 ] || fail "bridge answered without its token ($code)"
r=$(mq -auth TRANSLATION-BRIDGE-TOKEN -token "$bridge" -topic "$topic" -params "systemName=RandomDataProducer,serviceName=$service,count=3") || fail "bridge: no response"
printf '%s' "$r" | jq -e '.status == 200 and (.payload | length > 0 and all(.[]; has("name") and has("value") and (has("n") | not)))' >/dev/null || fail "not simpleJson over MQTT: $r"
echo "   simpleJson over MQTT: $(printf '%s' "$r" | jq -c '.payload[0]')"

sysop_login || fail "Sysop login"
used() {  # bridge id -> waits for the USED record
  rec=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    rec=$(curl -sS $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' --data "{\"bridgeIds\":[\"$1\"]}" "$TM/translation/bridge/mgmt/query" | jq -r '.entries[0] | "\(.status) \(.usageReportCount) \(.consumer)"')
    case "$rec" in USED*) break ;; esac
    sleep 1
  done
  echo "$rec"
}
abort() { curl -sS $SYSOP_TLS -H "$SYSOP_AUTH" -X DELETE "$TM/translation/bridge/mgmt/abort?ids=$1" | jq -r --arg b "$1" '.results[$b]'; }
rec=$(used "$bridge"); case "$rec" in "USED 1 SmokeClient") echo "   bridge record: $rec" ;; *) fail "bridge record: $rec" ;; esac
[ "$(abort "$bridge")" = true ] || fail "abort"
r=$(mq -auth TRANSLATION-BRIDGE-TOKEN -token "$bridge" -topic "$topic" -params "systemName=RandomDataProducer,serviceName=$service") || fail "aborted bridge: no response"
printf '%s' "$r" | jq -e '.status == 404' >/dev/null || fail "aborted bridge answered: $r"
echo "   aborted; the bridge answers 404"

# https_to_mqtt <label> <service definition> <provider> <operation> <body JSON> <query> <jq check of the response body>
https_to_mqtt() {
  label=$1 def=$2 provider=$3 op=$4 body=$5 query=$6 check=$7
  entry=$(smk --data "{\"serviceDefinitionNames\":[\"$def\"],\"providerNames\":[\"$provider\"]}" "$SR/serviceregistry/service-discovery/lookup" \
    | jq -c '.entries[0] // empty | .interfaces |= map(select(.templateName == "generic_mqtts"))')
  [ -n "$entry" ] && printf '%s' "$entry" | jq -e '.interfaces | length == 1' >/dev/null || fail "$label: no generic_mqtts offer of $provider: $entry"
  echo "   $provider $def: $(printf '%s' "$entry" | jq -r '.interfaces[0].properties.baseTopic')$op"
  disc=$(curl -sS $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' --data "{\"consumer\":\"SmokeClient\",\"candidates\":[$entry],\"operation\":\"$op\",\"interfaceTemplateNames\":[\"generic_https\"],\"flags\":{\"CANDIDATES_AUTH_CHECK\":false,\"CANDIDATES_BLACKLIST_CHECK\":true,\"TRANSLATORS_AUTH_CHECK\":true,\"TRANSLATORS_BLACKLIST_CHECK\":true}}" "$TM/translation/bridge/mgmt/discovery")
  id=$(printf '%s' "$disc" | jq -er '.bridgeId') || fail "$label discovery: $disc"
  neg=$(curl -sS $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' --data "{\"bridgeId\":\"$id\",\"targetInstanceId\":$(printf '%s' "$entry" | jq '.instanceId')}" "$TM/translation/bridge/mgmt/negotiation")
  bi=$(printf '%s' "$neg" | jq -c '.bridgeInterface')
  printf '%s' "$bi" | jq -e '.templateName == "generic_https" and .policy == "TRANSLATION_BRIDGE_TOKEN_AUTH"' >/dev/null || fail "$label negotiation: $neg"
  url="$(bridge_origin "$bi")$(printf '%s' "$bi" | jq -r --arg op "$op" '.properties.operations[$op].path')$query"
  code=$(curl -sS -o /dev/null -w '%{http_code}' $SMK -H "Authorization: Bearer TRANSLATION-BRIDGE-TOKEN//wrong" -H 'Content-Type: application/json' --data "$body" "$url")
  [ "$code" = 401 ] || fail "$label: bridge without its token answered $code"
  out=$(curl -sS -w '\n%{http_code}' $SMK -H "Authorization: Bearer TRANSLATION-BRIDGE-TOKEN//$id" -H 'Content-Type: application/json' --data "$body" "$url")
  code=$(printf '%s' "$out" | tail -n 1); out=$(printf '%s' "$out" | sed '$d')
  [ "$code" = 200 ] || fail "$label: bridge call answered $code: $out"
  printf '%s' "$out" | jq -e "$check" >/dev/null || fail "$label: unexpected result: $out"
  echo "   HTTPS bridge $id -> MQTT: $(printf '%s' "$out" | jq -c . | cut -c1-140)"
  rec=$(used "$id"); case "$rec" in "USED 1 SmokeClient") ;; *) fail "$label bridge record: $rec" ;; esac
  [ "$(abort "$id")" = true ] || fail "$label abort"
}

echo "== B1. HTTPS consumer -> Go DynamicServiceOrchestration over MQTT"
https_to_mqtt "Go DSO" serviceOrchestration DynamicServiceOrchestration pull \
  '{"serviceRequirement":{"serviceDefinition":"dataHistorian","operations":["get-data"],"interfaceTemplateNames":["generic_https"]},"orchestrationFlags":{"MATCHMAKING":true}}' "" \
  '.results[0].providerName == "DataManager"'

# C. Java Blacklist (make swap-java-blacklist): its MQTT API directly, then an HTTPS consumer through the bridge
if smk --data '{"serviceDefinitionNames":["blacklistDiscovery"]}' "$SR/serviceregistry/service-discovery/lookup" \
    | jq -e '.entries[0].interfaces | any(.templateName == "generic_mqtts")' >/dev/null 2>&1; then
  echo "== C. Java Blacklist over MQTT"
  r=$(mq -token "$token" -topic arrowhead/blacklist/check -payload '"SmokeClient"') || fail "Java Blacklist check over MQTT: no response"
  printf '%s' "$r" | jq -e '.status == 200 and .payload == false' >/dev/null || fail "Java Blacklist check over MQTT: $r"
  echo "   SmokeClient -> arrowhead/blacklist/check: $(printf '%s' "$r" | jq -c '{status,payload}')"
  https_to_mqtt "Java Blacklist" blacklistDiscovery Blacklist check '"SmokeClient"' "" '. == false'
else
  echo "== C. skipped: the Blacklist offers no generic_mqtts interface (Go Blacklist; make swap-java-blacklist)"
fi

# D. Rust TimeManager (make swap-rust-timemanager), HTTPS only: an MQTT consumer through the orchestrator and a bridge
implementation=$(curl -sS $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' --data '{"systemNames":["TimeManager"]}' \
  https://127.0.0.1:7443/serviceregistry/mgmt/systems/query | jq -r '.entries[0].metadata.implementation // empty')
if [ "$implementation" = Rust ]; then
  echo "== D. MQTT consumer -> Rust TimeManager (HTTPS only)"
  pull=$(mq -token "$token" -topic arrowhead/serviceorchestration/orchestration/pull -payload '{"serviceRequirement":{"serviceDefinition":"time","operations":["get-time"],"interfaceTemplateNames":["generic_mqtts"]},"orchestrationFlags":{"ALLOW_TRANSLATION":true,"MATCHMAKING":true}}') \
    || fail "orchestration over MQTT: no response"
  result=$(printf '%s' "$pull" | jq -c '.payload.results[0] // empty')
  printf '%s' "$result" | jq -e '.providerName == "TimeManager" and .interfaces[0].templateName == "generic_mqtts" and .interfaces[0].policy == "TRANSLATION_BRIDGE_TOKEN_AUTH"' >/dev/null \
    || fail "no MQTT bridge to the Rust TimeManager: $pull"
  bridge=$(printf '%s' "$result" | jq -er '.authorizationTokens.TRANSLATION_BRIDGE_TOKEN_AUTH["get-time"].token')
  topic=$(printf '%s' "$result" | jq -r '.interfaces[0].properties.baseTopic')get-time
  r=$(mq -auth TRANSLATION-BRIDGE-TOKEN -token "$bridge" -topic "$topic") || fail "Rust TimeManager bridge: no response"
  printf '%s' "$r" | jq -e '.status == 200 and (.payload.epochMs | type == "number")' >/dev/null || fail "Rust TimeManager over MQTT: $r"
  echo "   $topic: $(printf '%s' "$r" | jq -c '.payload | {epochMs, trusted, timeSource}')"
  rec=$(used "$bridge"); case "$rec" in "USED 1 SmokeClient") echo "   bridge record: $rec" ;; *) fail "Rust bridge record: $rec" ;; esac
  [ "$(abort "$bridge")" = true ] || fail "Rust bridge abort"
else
  echo "== D. skipped: TimeManager is not the Rust implementation (make swap-rust-timemanager)"
fi

echo "MQTT translation bridge tests passed"
