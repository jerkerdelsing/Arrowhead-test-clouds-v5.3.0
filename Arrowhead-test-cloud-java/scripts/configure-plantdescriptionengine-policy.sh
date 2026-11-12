#!/bin/sh
# ConsumerAuthorization policy for PlantDescriptionEngine's plantDescriptionMonitor service (operators). Its read
# access to SysMonitor's sysMonitorHistory is granted by configure-sysmonitor-policy.sh.
# Its sysMonitor policy is applied by configure-all-sysmonitor-policies.sh, which owns every sysMonitor policy.
# Re-running replaces the policies (scripts/lib-policies.sh).
set -eu

AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
MONITOR_CONSUMERS=${PDE_MONITOR_CONSUMERS:-'["LocalCloudManager","SmokeClient"]'}
PAYLOAD=$(jq -cn --argjson consumers "$MONITOR_CONSUMERS" '{list: [
  {provider: "PlantDescriptionEngine", targetType: "SERVICE_DEF", target: "plantDescriptionMonitor",
   description: "Operators that observe the plant and acknowledge alarms",
   defaultPolicy: {policyType: "WHITELIST", policyList: $consumers}}
]}')

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "PlantDescriptionEngine plantDescriptionMonitor policies configured"
