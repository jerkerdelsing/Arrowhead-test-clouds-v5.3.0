#!/bin/sh
# Re-running replaces the policies (scripts/lib-policies.sh).
# ConsumerAuthorization policy for SysMonitor's sysMonitorHistory service. SysMonitor stores the sysMonitor
# observations of all monitored microsystems itself and checks every history call against this policy
# (authorization.verify); the operations console (LocalCloudManager) reads it. Re-running replaces the policy.
set -eu

AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
INSTANCE='MGMT|LOCAL|SysMonitor|SERVICE_DEF|sysMonitorHistory'
PAYLOAD='{"list":[
  {"provider":"SysMonitor","targetType":"SERVICE_DEF","target":"sysMonitorHistory","description":"Stored sysMonitor observations of all microsystems; the operations console reads them","defaultPolicy":{"policyType":"WHITELIST","policyList":["LocalCloudManager","PlantDescriptionEngine"]}}
]}'

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "SysMonitor sysMonitorHistory policies configured"
