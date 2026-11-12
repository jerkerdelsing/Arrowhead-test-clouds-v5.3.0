#!/bin/sh
# Inter-cloud exchange with the neighbour clouds over the Arrowhead relay (../Arrowhead-relay).
#  1. Gatekeeper: the neighbour clouds of the own organization (gatekeeperManagement), as the operator Sysop (J6).
#  2. ConsumerAuthorization: which systems of a neighbour cloud may use a local provider. The provider-side
#     Gatekeeper checks these policies for global service discovery and inter-cloud negotiation; the provider
#     itself is then called by the local GateTunnel, which needs the local dataHistorian put-data grant
#     (configure-datamanager-policies.sh).
# Re-running is safe (scripts/lib-policies.sh).
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"
env_value() { value=$(sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1); printf '%s' "${value:-$2}"; }
AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:$(env_value CONSUMER_AUTHORIZATION_PORT 8445)}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:$(env_value AUTHENTICATION_PORT 8444)}
GATEKEEPER_URL=${GATEKEEPER_URL:-https://127.0.0.1:$(env_value GATEKEEPER_PORT 8449)}
CERT_DIR=${CERT_DIR:-security/x509}
ORGANIZATION=${ARROWHEAD_ORGANIZATION:-Company}
NEIGHBOR_CLOUDS=${NEIGHBOR_CLOUDS:-$(env_value NEIGHBOR_CLOUDS GoCloud)}
INTERCLOUD_PRODUCERS=${INTERCLOUD_PRODUCERS:-'["RandomDataProducer"]'}

. "$(dirname -- "$0")/lib-policies.sh"
policy_token

clouds=$(printf '%s' "$NEIGHBOR_CLOUDS" | tr ',' '\n' | jq -R --arg org "$ORGANIZATION" 'select(length > 0) | {name: ., operator: $org}' | jq -cs '{list: .}')
response=$(policy_call --data "$clouds" "$GATEKEEPER_URL/gatekeeper/mgmt/clouds")
printf '%s' "$response" | jq -e '.count > 0' >/dev/null || { echo "Unable to register neighbour clouds: $response" >&2; exit 1; }
echo "Gatekeeper neighbour clouds: $(printf '%s' "$response" | jq -r '[.entries[] | "\(.name)|\(.operator)"] | join(", ")')"

for cloud in $(printf '%s' "$NEIGHBOR_CLOUDS" | tr ',' ' '); do
  apply_policies "$(jq -cn --arg cloud "$cloud|$ORGANIZATION" --argjson producers "$INTERCLOUD_PRODUCERS" '{list: [
    {cloud: $cloud, provider: "DataManager", targetType: "SERVICE_DEF", target: "dataHistorian",
     description: "Inter-cloud producers of the neighbour cloud store data",
     defaultPolicy: {policyType: "WHITELIST", policyList: $producers}, scopedPolicies: {}}]}')"
done
# The Gatekeeper checks inter-cloud consumers with authorizationManagement.check-policies (an intermediary cannot
# use authorization.verify); it gets that operation only. The policy has other consumers too and is declared in
# configure-orchestration-dependency-policies.sh.
echo "Inter-cloud policies configured"
