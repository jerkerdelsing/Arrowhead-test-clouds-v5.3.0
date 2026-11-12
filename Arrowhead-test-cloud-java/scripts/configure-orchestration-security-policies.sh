#!/bin/sh
# Re-running replaces the policies (scripts/lib-policies.sh).
set -eu
. "$(dirname -- "$0")/lib-secrets.sh"
_require_secret=$(secret ARROWHEAD_SYSOP_PASSWORD)
. "$(dirname "$0")/registry-auth.sh"

AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}

# ConsumerAuthorization has no Docker health check and `make up` runs this
# script before the full stack is up. Wait until Authentication issues a token
# and ConsumerAuthorization accepts it.
authorized_echo() {
  echo_token=$(curl -fsS --max-time 5 --cacert "$CERT_DIR/ca.crt" \
    --cert "$CERT_DIR/sysop.crt" --key "$CERT_DIR/sysop.key" \
    -H 'Content-Type: application/json' \
    --data "{\"systemName\":\"Sysop\",\"credentials\":{\"password\":\"$(secret ARROWHEAD_SYSOP_PASSWORD)\"}}" \
    "$AUTHENTICATION_URL/authentication/identity/login" 2>/dev/null | jq -er '.token' 2>/dev/null) || return 1
  curl -fsS -o /dev/null --max-time 5 --cacert "$CERT_DIR/ca.crt" \
    --cert "$CERT_DIR/sysop.crt" --key "$CERT_DIR/sysop.key" \
    -H "Authorization: Bearer IDENTITY-TOKEN//$echo_token" \
    "$AUTHORIZATION_URL/consumerauthorization/monitor/echo" 2>/dev/null
}
attempt=0
until authorized_echo; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    echo "ConsumerAuthorization did not become ready within 5 minutes" >&2
    exit 1
  fi
  sleep 5
done

# A secured DSO only consumes CERT_AUTH interfaces; the mTLS registry registers generalManagement that way. Verify it.
sysop_login
if ! curl -fsS --max-time 10 -X POST \
    $SYSOP_TLS -H "$SYSOP_AUTH" \
    -H 'Content-Type: application/json' \
    --data '{"providerNames":["ServiceRegistry"],"serviceDefinitionNames":["generalManagement"]}' \
    https://127.0.0.1:8443/serviceregistry/mgmt/service-instances/query \
  | jq -e '[.entries[].interfaces[] | select(.templateName == "generic_https" and .policy == "CERT_AUTH")] | length > 0' >/dev/null; then
  echo "ServiceRegistry generalManagement is not registered as generic_https/CERT_AUTH" >&2
  exit 1
fi
echo "ServiceRegistry secure generalManagement interface present"

# DynamicServiceOrchestration resolves ServiceRegistry's interface address
# types through generalManagement during startup. In authorized mode this
# bootstrap dependency must be granted explicitly or v5.2.2 reports the
# service as missing and restarts indefinitely.
PAYLOAD='{"list":[
  {"provider":"ServiceRegistry","targetType":"SERVICE_DEF","target":"generalManagement","description":"Allow DynamicServiceOrchestration to initialize interface address type filtering","defaultPolicy":{"policyType":"WHITELIST","policyList":["DynamicServiceOrchestration"]},"scopedPolicies":{}}
]}'

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "DynamicServiceOrchestration bootstrap policies configured"
