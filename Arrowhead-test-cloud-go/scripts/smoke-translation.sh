#!/bin/sh
# Translation bridge end to end (2026-10-24), the v5.2 consumer path: SmokeClient asks DynamicServiceOrchestration for
# DataManager get-data in simpleJson (ALLOW_TRANSLATION); the orchestrator has the TranslationManager discover and
# negotiate a bridge through the TestTranslation interface/data model translator; the bridge serves senml as
# simpleJson. SmokeClient is the consumer (never a running system); Sysop checks and aborts the bridge
# (translationBridgeManagement).
set -eu
cd "$(dirname "$0")/.."
. scripts/lib-secrets.sh
. scripts/registry-auth.sh
CERT_DIR=${CERT_DIR:-security/x509}
SMK="--cacert $CERT_DIR/ca.crt --cert $CERT_DIR/smoke-client.crt --key $CERT_DIR/smoke-client.key"
DSO=https://127.0.0.1:7441 TM=https://127.0.0.1:7465 DM=https://127.0.0.1:7461
fail() { echo "FAIL: $*" >&2; exit 1; }

token=$(curl -fsS $SMK -H 'Content-Type: application/json' \
  --data "{\"systemName\":\"SmokeClient\",\"credentials\":{\"password\":\"$(secret AH_PW_SMK)\"}}" \
  https://127.0.0.1:7444/authentication/identity/login | jq -er '.token')
AUTH="Authorization: Bearer IDENTITY-TOKEN//$token"
smk() { curl -sS $SMK -H "$AUTH" -H 'Content-Type: application/json' "$@"; }
service=$(smk "$DM/datamanager/data-historian/systems/RandomDataProducer/services" | jq -er '.services[0]')

echo "== 1. Without a data model requirement the DataManager is orchestrated natively"
native=$(smk -X POST --data '{"serviceRequirement":{"serviceDefinition":"dataHistorian","operations":["get-data"],"interfaceTemplateNames":["generic_https"]},"orchestrationFlags":{"ALLOW_TRANSLATION":true,"MATCHMAKING":true}}' "$DSO/serviceorchestration/orchestration/pull")
printf '%s' "$native" | jq -e '.results[0].providerName == "DataManager" and .results[0].interfaces[0].policy != "TRANSLATION_BRIDGE_TOKEN_AUTH"' >/dev/null \
  || fail "native orchestration: $native"

echo "== 2. simpleJson output: the orchestrator returns a translation bridge"
pull=$(smk -X POST --data '{"serviceRequirement":{"serviceDefinition":"dataHistorian","operations":["get-data"],"interfaceTemplateNames":["generic_https"],"interfacePropertyRequirements":[{"dataModels.get-data.output":{"op":"EQUALS","value":"simpleJson"}}]},"orchestrationFlags":{"ALLOW_TRANSLATION":true,"MATCHMAKING":true}}' "$DSO/serviceorchestration/orchestration/pull")
result=$(printf '%s' "$pull" | jq -c '.results[0] // empty')
[ -n "$result" ] || fail "no orchestration result: $pull"
intf=$(printf '%s' "$result" | jq -c '.interfaces[0]')
printf '%s' "$intf" | jq -e '.policy == "TRANSLATION_BRIDGE_TOKEN_AUTH"' >/dev/null || fail "not a bridge interface: $result"
bridge=$(printf '%s' "$result" | jq -er '.authorizationTokens.TRANSLATION_BRIDGE_TOKEN_AUTH["get-data"].token')
origin=$(printf '%s' "$intf" | jq -r '"https://127.0.0.1:" + (if .properties.accessAddresses[0] == "test-translation" then "7466" else (.properties.accessPort|tostring) end) + .properties.basePath')
path=$(printf '%s' "$intf" | jq -r '.properties.operations["get-data"].path' | sed "s/{systemName}/RandomDataProducer/; s/{serviceName}/$service/")
echo "   bridge $bridge (provider $(printf '%s' "$result" | jq -r .providerName), via $(printf '%s' "$intf" | jq -r '.properties.accessAddresses[0]'))"

echo "== 3. Calls over the bridge"
bridge_call() {
  curl -sS -o /tmp/smoke-translation.$$ -w '%{http_code}' $SMK -H "Authorization: $1" "$origin$path?count=3"
}
code=$(bridge_call "Bearer TRANSLATION-BRIDGE-TOKEN//not-the-bridge")
[ "$code" = 401 ] || fail "bridge call without its token answered $code"
code=$(bridge_call "Bearer TRANSLATION-BRIDGE-TOKEN//$bridge")
body=$(cat /tmp/smoke-translation.$$); rm -f /tmp/smoke-translation.$$
[ "$code" = 200 ] || fail "bridge call answered $code: $body"
printf '%s' "$body" | jq -e 'length > 0 and all(.[]; has("name") and has("value") and (has("n") | not))' >/dev/null \
  || fail "result is not simpleJson: $body"
echo "   simpleJson: $(printf '%s' "$body" | jq -c '.[0]')"

echo "== 4. The translator reported the use to the TranslationManager"
sysop_login || fail "Sysop login"
record=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  record=$(curl -sS $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' --data "{\"bridgeIds\":[\"$bridge\"]}" "$TM/translation/bridge/mgmt/query" \
    | jq -r '.entries[0] | "\(.status) \(.usageReportCount) \(.consumer) \(.createdBy) \(.interfaceTranslator) \(.outputDataModelTranslator)"')
  case "$record" in USED*) break ;; esac
  sleep 1
done
case "$record" in "USED 1 SmokeClient DynamicServiceOrchestration TestTranslation TestTranslation") echo "   bridge record: $record" ;; *) fail "bridge record: $record" ;; esac

echo "== 5. Abort (management)"
aborted=$(curl -sS $SYSOP_TLS -H "$SYSOP_AUTH" -X DELETE "$TM/translation/bridge/mgmt/abort?ids=$bridge" | jq -r --arg b "$bridge" '.results[$b]')
[ "$aborted" = true ] || fail "abort answered $aborted"
code=$(bridge_call "Bearer TRANSLATION-BRIDGE-TOKEN//$bridge"); rm -f /tmp/smoke-translation.$$
[ "$code" = 404 ] || fail "aborted bridge answered $code"
echo "   aborted; the bridge no longer forwards"
echo "Translation bridge end-to-end test passed"
