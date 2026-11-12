#!/bin/sh
# MQTT API of the Go core systems (2026-10-24, Java mqtt.api.enabled): requests in the Java envelope on the local
# broker, answered on arrowhead/response/<requester>/... SmokeClient is the consumer (never a running system); Sysop
# checks management. Uses ../ah5-core-go/cmd/mqtt-call (built for the host into go-native-full/host).
set -eu
cd "$(dirname "$0")/.."
. scripts/lib-secrets.sh
. scripts/registry-auth.sh
CERT_DIR=${CERT_DIR:-security/x509}
MQTT_PORT=$(sed -n 's/^MQTT_TLS_PORT=//p' .env | tail -n 1)
TOOL=go-native-full/host/mqtt-call
mkdir -p go-native-full/host
(cd ../ah5-core-go && go build -trimpath -o "../Arrowhead-test-cloud-go/$TOOL" ./cmd/mqtt-call)
fail() { echo "FAIL: $*" >&2; exit 1; }
# call <system> <cert stem> <token> <topic> [mqtt-call options]
call() {
  sys=$1 stem=$2 tok=$3 topic=$4
  shift 4
  "$TOOL" -broker "ssl://127.0.0.1:${MQTT_PORT:-8883}" -ca "$CERT_DIR/ca.crt" -cert "$CERT_DIR/$stem.crt" -key "$CERT_DIR/$stem.key" \
    -system "$sys" -token "$tok" -topic "$topic" "$@"
}
smk() { call SmokeClient smoke-client "$token" "$@"; }

token=$(curl -fsS --cacert $CERT_DIR/ca.crt --cert $CERT_DIR/smoke-client.crt --key $CERT_DIR/smoke-client.key -H 'Content-Type: application/json' \
  --data "{\"systemName\":\"SmokeClient\",\"credentials\":{\"password\":\"$(secret AH_PW_SMK)\"}}" \
  https://127.0.0.1:7444/authentication/identity/login | jq -er '.token')

echo "== 1. Echo of every core system over MQTT"
for base in arrowhead/serviceregistry arrowhead/authentication arrowhead/consumer-authorization arrowhead/serviceorchestration arrowhead/serviceorchestration-simple; do
  r=$(smk "$base/monitor/echo") || fail "$base echo: no response"
  printf '%s' "$r" | jq -e '.status == 200 and .payload == "Got it!" and .receiver == "SmokeClient"' >/dev/null || fail "$base echo: $r"
  echo "   $base: $(printf '%s' "$r" | jq -c '{status,payload}')"
done

echo "== 2. Service operations"
r=$(smk arrowhead/authentication/identity/identity-verify -payload "\"$token\"")
printf '%s' "$r" | jq -e '.status == 200 and .payload.verified == true and .payload.systemName == "SmokeClient"' >/dev/null || fail "identity-verify: $r"
echo "   Authentication identity-verify: verified"
r=$(smk arrowhead/serviceregistry/service-discovery/lookup -params verbose=false -payload '{"serviceDefinitionNames":["serviceOrchestration"]}')
printf '%s' "$r" | jq -e '.status == 200 and (.payload.entries | length) > 0' >/dev/null || fail "SR lookup: $r"
echo "   ServiceRegistry service-discovery lookup: $(printf '%s' "$r" | jq -c '[.payload.entries[] | .provider.name // .provider] | unique')"
r=$(smk arrowhead/consumer-authorization/authorization-token/get-public-key)
printf '%s' "$r" | jq -e '.status == 200' >/dev/null || fail "get-public-key: $r"
echo "   ConsumerAuthorization get-public-key: 200"
r=$(smk arrowhead/serviceorchestration/orchestration/pull -payload '{"serviceRequirement":{"serviceDefinition":"dataHistorian","operations":["get-data"],"interfaceTemplateNames":["generic_https"]},"orchestrationFlags":{"MATCHMAKING":true}}')
printf '%s' "$r" | jq -e '.status == 200 and .payload.results[0].providerName == "DataManager"' >/dev/null || fail "DSO pull: $r"
echo "   DynamicServiceOrchestration pull: DataManager"

echo "== 3. Management over MQTT (management filter as over HTTPS)"
r=$(smk arrowhead/authentication/identity/management/identity-mgmt-query -payload '{}')
printf '%s' "$r" | jq -e '.status == 403 and .payload.exceptionType == "FORBIDDEN"' >/dev/null || fail "SmokeClient management: $r"
echo "   SmokeClient identity-mgmt-query: 403"
sysop_login || fail "Sysop login"
r=$(call Sysop sysop "$_sysop_token" arrowhead/serviceregistry/management/service-query -payload '{"serviceDefinitionNames":["serviceOrchestration"],"providerNames":["DynamicServiceOrchestration"]}')
printf '%s' "$r" | jq -e '.status == 200 and ([.payload.entries[].interfaces[] | select(.templateName == "generic_mqtts") | .properties.baseTopic] | index("arrowhead/serviceorchestration/orchestration/")) != null' >/dev/null \
  || fail "Sysop service-query (generic_mqtts registration): $r"
echo "   Sysop service-query: DynamicServiceOrchestration registered with generic_mqtts arrowhead/serviceorchestration/orchestration/"

echo "== 4. Refusals"
code=0; smk arrowhead/authentication/monitor/echo -token not-a-token -timeout 3s >/dev/null 2>&1 || code=$?
[ "$code" = 2 ] || fail "invalid token was answered ($code)"
echo "   invalid token: not answered"
code=0; smk arrowhead/authentication/monitor/echo -response-topic "arrowhead/response/Sysop/smoke" -listen "arrowhead/response/SmokeClient/#" -timeout 3s >/dev/null 2>&1 || code=$?
[ "$code" = 2 ] || fail "response to a foreign topic ($code)"
echo "   response topic of another system: not answered"
r=$(smk arrowhead/authentication/identity/identity-login -payload '{"systemName":"SmokeClient","credentials":{"password":"x"}}')
printf '%s' "$r" | jq -e '.status == 401' >/dev/null || fail "login over MQTT: $r"
echo "   identity-login over MQTT: 401 (HTTPS only)"
echo "MQTT API end-to-end test passed"
