#!/bin/sh
# ConsumerAuthorization policies for Choreographer: DynamicServiceOrchestration push management (Choreographer
# orchestrates for its executors), its choreographerSession service (clients start plans), its choreographerExecutor
# service (executor systems register and report step results). Executors also need grants for the services their
# steps consume.
# Its sysMonitor policy is applied by configure-all-sysmonitor-policies.sh, which owns every sysMonitor policy.
# Re-running replaces the policies (scripts/lib-policies.sh).
set -eu

AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
SESSION_CLIENTS=${CHOREOGRAPHER_SESSION_CLIENTS:-'["Sysop"]'}
EXECUTORS=${CHOREOGRAPHER_EXECUTORS:-'["Sysop"]'}
PAYLOAD=$(jq -cn --argjson clients "$SESSION_CLIENTS" --argjson executors "$EXECUTORS" '{list: [
  {provider: "DynamicServiceOrchestration", targetType: "SERVICE_DEF", target: "serviceOrchestrationPushManagement",
   description: "Choreographer orchestrates on behalf of its executors",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["Choreographer"]}},
  {provider: "Choreographer", targetType: "SERVICE_DEF", target: "choreographerSession",
   description: "Systems that start and abort workflow sessions",
   defaultPolicy: {policyType: "WHITELIST", policyList: $clients}},
  {provider: "Choreographer", targetType: "SERVICE_DEF", target: "choreographerExecutor",
   description: "Executor systems that perform plan steps",
   defaultPolicy: {policyType: "WHITELIST", policyList: $executors}}
]}')

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "Choreographer push-orchestration, choreographerSession and choreographerExecutor policies configured"
