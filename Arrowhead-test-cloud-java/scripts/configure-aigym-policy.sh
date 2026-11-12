#!/bin/sh
# ConsumerAuthorization policies for AIGym: the test identity SmokeClient may use aiGym (smoke-aigym.sh; J6: not the
# console identity LocalCloudManager), and AIGym may consume SysMonitor's
# sysMonitorData.
# Its sysMonitor policy is applied by configure-all-sysmonitor-policies.sh, which owns every sysMonitor policy.
# Re-running replaces the policies (scripts/lib-policies.sh).
set -eu
AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
PAYLOAD='{"list":[
 {"provider":"AIGym","targetType":"SERVICE_DEF","target":"aiGym","description":"SmokeClient test access to AIGym","defaultPolicy":{"policyType":"WHITELIST","policyList":["SmokeClient"]},"scopedPolicies":{"status":{"policyType":"WHITELIST","policyList":["SmokeClient"]},"add-sample":{"policyType":"WHITELIST","policyList":["SmokeClient"]},"predict":{"policyType":"WHITELIST","policyList":["SmokeClient"]},"observations":{"policyType":"WHITELIST","policyList":["SmokeClient"]}}},
 {"provider":"SysMonitor","targetType":"SERVICE_DEF","target":"sysMonitorData","description":"AIGym may consume normalized monitoring data","defaultPolicy":{"policyType":"WHITELIST","policyList":["AIGym"]},"scopedPolicies":{"subscribe":{"policyType":"WHITELIST","policyList":["AIGym"]}}}
]}'

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "AIGym aiGym and sysMonitorData policies configured"
