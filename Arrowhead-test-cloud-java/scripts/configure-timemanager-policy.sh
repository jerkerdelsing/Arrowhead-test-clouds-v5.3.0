#!/bin/sh
# ConsumerAuthorization policy for TimeManager's time service (orchestration and consumption).
# Its sysMonitor policy is applied by configure-all-sysmonitor-policies.sh, which owns every sysMonitor policy.
# Re-running replaces the policies (scripts/lib-policies.sh).
set -eu

AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
TIME_CONSUMERS=${TIMEMANAGER_TIME_CONSUMERS:-'["RandomDataProducer","SysMonitor","AIGym","SmokeClient"]'}
PAYLOAD=$(jq -cn --argjson consumers "$TIME_CONSUMERS" '{list: [
  {provider: "TimeManager", targetType: "SERVICE_DEF", target: "time",
   description: "Systems that read the trusted local-cloud time",
   defaultPolicy: {policyType: "WHITELIST", policyList: $consumers}}
]}')

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "TimeManager time policies configured"
