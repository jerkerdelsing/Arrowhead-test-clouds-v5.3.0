#!/bin/sh
set -eu
. "$(dirname "$0")/registry-auth.sh"

REGISTRY_URL=${SERVICE_REGISTRY_URL:-https://127.0.0.1:8443}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}

attempt=0
until curl -fsS --cacert "$CERT_DIR/ca.crt" \
  --cert "$CERT_DIR/local-cloud-manager.crt" \
  --key "$CERT_DIR/local-cloud-manager.key" \
  "$AUTHENTICATION_URL/authentication/monitor/echo" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    echo "Authentication did not become ready with mTLS within 5 minutes" >&2
    exit 1
  fi
  sleep 5
done

registry_post() {
  path=$1
  payload=$2
  curl -fsS \
    $SYSOP_TLS -H "$SYSOP_AUTH" \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    "$REGISTRY_URL$path" >/dev/null
}

register_service() {
  service=$1
  base_path=$2
  operations=$3
  registry_post /serviceregistry/service-discovery/register \
    "{\"serviceDefinitionName\":\"$service\",\"version\":\"1.0.0\",\"expiresAt\":null,\"metadata\":{},\"interfaces\":[{\"templateName\":\"generic_https\",\"protocol\":\"https\",\"policy\":\"CERT_AUTH\",\"properties\":{\"accessAddresses\":[\"authentication\"],\"accessPort\":8444,\"basePath\":\"$base_path\",\"operations\":$operations}}]}"
}

IDENTITY_OPERATIONS='{"identity-login":{"method":"POST","path":"/login"},"identity-logout":{"method":"POST","path":"/logout"},"identity-change":{"method":"POST","path":"/change"},"identity-verify":{"method":"GET","path":"/verify"}}'

# Authentication registers identity itself at every start-up with CERT_AUTH
# (SERVICE_INTERFACE_POLICY in compose.yaml), so it survives restarts. Verify it, and that no plain HTTP interface remains;
# right after a restart the self-registration can lag the echo check, so retry.
attempt=0
until sysop_login && curl -fsS --max-time 10 -X POST \
    $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' \
    --data '{"providerNames":["Authentication"],"serviceDefinitionNames":["identity"]}' \
    "$REGISTRY_URL/serviceregistry/mgmt/service-instances/query" \
  | jq -e '[.entries[].interfaces[]] | (map(select(.templateName == "generic_https" and .policy == "CERT_AUTH")) | length > 0)
           and (map(select(.templateName == "generic_http")) | length == 0)' >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    echo "Authentication identity is not CERT_AUTH-only; check SERVICE_INTERFACE_POLICY" >&2
    exit 1
  fi
  sleep 2
done

echo "Authentication identity service is mTLS (CERT_AUTH) only"
