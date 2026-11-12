#!/bin/sh
# ConsumerAuthorization policies for Configuration: its configuration service (systems read their own configuration)
# and its configurationProxy service (checked by Configuration for every call).
# Its sysMonitor policy is applied by configure-all-sysmonitor-policies.sh, which owns every sysMonitor policy.
# Re-running replaces the policies (scripts/lib-policies.sh).
set -eu

AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
CONSUMERS=${CONFIGURATION_CONSUMERS:-'["RandomDataProducer","SysMonitor","AIGym","TimeManager","DataManager"]'}
PROXIES=${CONFIGURATION_PROXIES:-'["Sysop"]'}
PAYLOAD=$(jq -cn --argjson consumers "$CONSUMERS" --argjson proxies "$PROXIES" '{list: [
  {provider: "Configuration", targetType: "SERVICE_DEF", target: "configuration",
   description: "Systems that fetch their own configuration",
   defaultPolicy: {policyType: "WHITELIST", policyList: $consumers}},
  {provider: "Configuration", targetType: "SERVICE_DEF", target: "configurationProxy",
   description: "Systems that read and store configurations on behalf of other systems",
   defaultPolicy: {policyType: "WHITELIST", policyList: $proxies}}
]}')

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "Configuration configuration and configurationProxy policies configured"
