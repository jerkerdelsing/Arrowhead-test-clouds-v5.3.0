#!/bin/sh
set -eu
. "$(dirname -- "$0")/lib-secrets.sh"
_require_secret=$(secret ARROWHEAD_SYSOP_PASSWORD)
_require_secret=$(secret AH_PW_SMK)
CERT_DIR=${CERT_DIR:-security/x509}
# The test identity SmokeClient (granted aiGym by configure-aigym-policy.sh), never a running system's identity (J6).
token=$(curl -fsS --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/smoke-client.crt" --key "$CERT_DIR/smoke-client.key" \
  -H 'Content-Type: application/json' --data "{\"systemName\":\"SmokeClient\",\"credentials\":{\"password\":\"$(secret AH_PW_SMK)\"}}" \
  https://127.0.0.1:7444/authentication/identity/login | jq -er '.token')
auth="Authorization: Bearer IDENTITY-TOKEN//$token"
curl -fsS --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/smoke-client.crt" --key "$CERT_DIR/smoke-client.key" \
  -H "$auth" -H 'Content-Type: application/json' --data '{"model":"smoke","features":{"x":0},"target":10}' https://127.0.0.1:7478/aigym/samples | jq -e '.model == "smoke"' >/dev/null
curl -fsS --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/smoke-client.crt" --key "$CERT_DIR/smoke-client.key" \
  -H "$auth" -H 'Content-Type: application/json' --data '{"model":"smoke","features":{"x":0},"neighbours":1}' https://127.0.0.1:7478/aigym/predict | jq -e '.value == 10' >/dev/null
curl -fsS --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/smoke-client.crt" --key "$CERT_DIR/smoke-client.key" \
  -H "$auth" https://127.0.0.1:7478/aigym/status | jq -e '.registration.registered == true and .mqtt.connected == true and (.sysMonitorData.topic | length > 0)' >/dev/null
# sysMonitorData is flowing (2026-10-24): AIGym received an observation from SysMonitor's MQTT output in the last
# two minutes (every system publishes every 30 s), whichever SysMonitor implementation runs (Go or Rust)
latest=$(curl -fsS --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/smoke-client.crt" --key "$CERT_DIR/smoke-client.key" \
  -H "$auth" https://127.0.0.1:7478/aigym/observations \
  | jq -r '(if type == "array" then . else (.observations // .entries // []) end) | map(.receivedByAIGym // empty) | max // ""')
[ -n "$latest" ] && [ $(( $(date -u +%s) - $(jq -rn --arg t "$latest" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601') )) -le 120 ] \
  || { echo "AIGym received no recent sysMonitorData observation (latest: ${latest:-none})" >&2; exit 1; }
code=$(curl -sS -o /dev/null -w '%{http_code}' --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/aigym.crt" --key "$CERT_DIR/aigym.key" https://127.0.0.1:7478/aigym/status)
test "$code" = 401
# Negative authorization: an authenticated identity without an aiGym grant (the operator Sysop) is refused with 403.
# Logging in as a running system (e.g. AIGym) would replace the identity token that system uses for its own calls.
other_token=$(curl -fsS --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/sysop.crt" --key "$CERT_DIR/sysop.key" \
  -H 'Content-Type: application/json' --data "{\"systemName\":\"Sysop\",\"credentials\":{\"password\":\"$(secret ARROWHEAD_SYSOP_PASSWORD)\"}}" \
  https://127.0.0.1:7444/authentication/identity/login | jq -er '.token')
code=$(curl -sS -o /dev/null -w '%{http_code}' --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/sysop.crt" --key "$CERT_DIR/sysop.key" \
  -H "Authorization: Bearer IDENTITY-TOKEN//$other_token" https://127.0.0.1:7478/aigym/status)
test "$code" = 403
echo 'AI-gym authenticated, authorized, inference, MQTT, and negative-auth smoke tests passed'
