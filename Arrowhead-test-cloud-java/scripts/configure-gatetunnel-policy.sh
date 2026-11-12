#!/bin/sh
# Re-running replaces the policies (scripts/lib-policies.sh).
set -eu
AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
. "$(dirname -- "$0")/lib-policies.sh"

grant() {
  target=$1
  consumers=$2
  apply_policies "$(jq -cn --arg target "$target" --argjson consumers "$consumers" '{list: [
    {provider: "GateTunnel", targetType: "SERVICE_DEF", target: $target, description: "GateTunnel v5.2.2 authorized consumers",
     defaultPolicy: {policyType: "WHITELIST", policyList: $consumers}, scopedPolicies: {}}]}')"
}
grant gateTunnelConnection '["Gatekeeper","DynamicServiceOrchestration","SimpleStoreServiceOrchestration"]'
grant gateTunnelKey '["Gatekeeper","DynamicServiceOrchestration","SimpleStoreServiceOrchestration"]'
grant gateTunnelManagement '["LocalCloudManager"]'
