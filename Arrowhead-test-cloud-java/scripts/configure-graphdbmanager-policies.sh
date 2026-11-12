#!/bin/sh
# Re-running replaces the policies (scripts/lib-policies.sh).
# ConsumerAuthorization policies for GraphDBManager (DataManager copy on GraphDB). DSO uses them for orchestration,
# and GraphDBManager checks every call against them (authorization.verify). SmokeClient writes and reads both
# services in smoke-test.sh; the operations console reads them.
set -eu

AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
PAYLOAD='{"list":[
  {"provider":"GraphDBManager","targetType":"SERVICE_DEF","target":"graphDataHistorian","description":"SenML history in GraphDB; producers and SmokeClient (smoke-test.sh) store, the console and SmokeClient read","defaultPolicy":{"policyType":"WHITELIST","policyList":["LocalCloudManager","SmokeClient"]},"scopedPolicies":{"put-data":{"policyType":"WHITELIST","policyList":["RandomDataProducer","SmokeClient"]}}},
  {"provider":"GraphDBManager","targetType":"SERVICE_DEF","target":"graphDataProxy","description":"Latest SenML values; producers and SmokeClient publish, the console and SmokeClient read","defaultPolicy":{"policyType":"WHITELIST","policyList":["LocalCloudManager","SmokeClient"]},"scopedPolicies":{"put-data":{"policyType":"WHITELIST","policyList":["RandomDataProducer","SmokeClient"]}}}
]}'

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "GraphDBManager graphDataHistorian and graphDataProxy policies configured"
