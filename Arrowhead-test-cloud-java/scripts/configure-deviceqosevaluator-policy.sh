#!/bin/sh
# ConsumerAuthorization policy for DeviceQoSEvaluator's qualityEvaluation service (filter, sort). Since release 5.3.0
# DeviceQoSEvaluator asks ConsumerAuthorization for every call; its consumer is DynamicServiceOrchestration, which
# evaluates the QoS requirements of orchestration requests. Its sysMonitor policy is applied by
# configure-all-sysmonitor-policies.sh. Re-running replaces the policy (scripts/lib-policies.sh).
set -eu

AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
CONSUMERS=${DEVICEQOSEVALUATOR_QUALITY_EVALUATION_CONSUMERS:-'["DynamicServiceOrchestration"]'}
PAYLOAD=$(jq -cn --argjson consumers "$CONSUMERS" '{list: [
  {provider: "DeviceQoSEvaluator", targetType: "SERVICE_DEF", target: "qualityEvaluation",
   description: "Systems that filter or sort providers by device QoS",
   defaultPolicy: {policyType: "WHITELIST", policyList: $consumers}}
]}')

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "DeviceQoSEvaluator qualityEvaluation policy configured"
