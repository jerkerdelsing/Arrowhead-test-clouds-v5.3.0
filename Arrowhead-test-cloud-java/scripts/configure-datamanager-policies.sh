#!/bin/sh
# Re-running replaces the policies (scripts/lib-policies.sh).
# ConsumerAuthorization policies for the Java DataManager. ConsumerAuthorization keeps one policy per
# provider/service definition, so all consumers of a service are granted here together. DSO uses these
# policies for orchestration, and DataManager checks every call against them (authorization.verify).
# sysMonitor observations are stored by SysMonitor itself (sysMonitorHistory), so SysMonitor is not a writer here.
# Re-running replaces existing policies.
set -eu

AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
PAYLOAD='{"list":[
  {"provider":"DataManager","targetType":"SERVICE_DEF","target":"dataHistorian","description":"Producers store data (GateTunnel on behalf of inter-cloud consumers); the operations console reads it (SmokeClient: smoke-test.sh)","defaultPolicy":{"policyType":"WHITELIST","policyList":["LocalCloudManager","SmokeClient"]},"scopedPolicies":{"put-data":{"policyType":"WHITELIST","policyList":["RandomDataProducer","GateTunnel","DemoSensor"]}}},
  {"provider":"DataManager","targetType":"SERVICE_DEF","target":"dataProxy","description":"Producers publish latest values; the operations console reads them","defaultPolicy":{"policyType":"WHITELIST","policyList":["LocalCloudManager"]},"scopedPolicies":{"put-data":{"policyType":"WHITELIST","policyList":["RandomDataProducer"]}}}
]}'

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "DataManager dataHistorian and dataProxy policies configured"
