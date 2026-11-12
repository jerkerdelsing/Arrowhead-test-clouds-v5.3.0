#!/bin/sh
set -eu
. "$(dirname "$0")/registry-auth.sh"

REGISTRY_URL=${SERVICE_REGISTRY_URL:-https://127.0.0.1:8443}

# The v5 images do not publish a Docker health check. Wait for the HTTP API,
# otherwise Compose's service_started condition races the Java application.
attempt=0
# The registry verifies the Sysop token with Authentication, so this also waits for the registry's own login.
until sysop_login && curl -fsS --max-time 5 $SYSOP_TLS -H "$SYSOP_AUTH" \
  "$REGISTRY_URL/serviceregistry/monitor/echo" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    echo "ServiceRegistry did not become ready within 5 minutes" >&2
    exit 1
  fi
  sleep 5
done

# The registry itself runs mutual TLS with outsourced (token) authentication and registers its own services as
# generic_https/CERT_AUTH at every start-up, so they survive restarts. Verify them.
# Right after a (re)start the self-registration can lag the echo check, so retry.
check() {
instances=$(curl -fsS --max-time 10 -X POST \
  $SYSOP_TLS -H "$SYSOP_AUTH" \
  -H 'Content-Type: application/json' \
  --data '{"providerNames":["ServiceRegistry"]}' \
  "$REGISTRY_URL/serviceregistry/mgmt/service-instances/query")
for definition in systemDiscovery serviceDiscovery deviceDiscovery; do
  if ! printf '%s' "$instances" | jq -e --arg d "$definition" \
      '[.entries[] | select(.serviceDefinition.name == $d) | .interfaces[]
        | select(.templateName == "generic_https" and .policy == "CERT_AUTH"
                 and .properties.accessAddresses[0] == "serviceregistry")] | length > 0' >/dev/null; then
    echo "ServiceRegistry $definition is not registered as generic_https/CERT_AUTH; check the registry TLS settings" >&2
    return 1
  fi
done

}
attempt=0
until check 2>/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    check
    exit 1
  fi
  sleep 2
done

echo "ServiceRegistry discovery is mTLS with CERT_AUTH discovery"
