#!/bin/sh
# ConsumerAuthorization policies for EventHandler's eventPublish and eventSubscription services (orchestration
# and consumption; EventHandler checks every publish, subscribe and unsubscribe with authorization.verify).
# Its sysMonitor policy is applied by configure-all-sysmonitor-policies.sh, which owns every sysMonitor policy.
# Re-running replaces the policies (scripts/lib-policies.sh).
set -eu

AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
PUBLISHERS=${EVENTHANDLER_PUBLISHERS:-'["RandomDataProducer","SysMonitor","PlantDescriptionEngine"]'}
SUBSCRIBERS=${EVENTHANDLER_SUBSCRIBERS:-'["RandomDataProducer","SysMonitor","AIGym"]'}
PAYLOAD=$(jq -cn --argjson publishers "$PUBLISHERS" --argjson subscribers "$SUBSCRIBERS" '{list: [
  {provider: "EventHandler", targetType: "SERVICE_DEF", target: "eventPublish",
   description: "Systems that publish events through EventHandler",
   defaultPolicy: {policyType: "WHITELIST", policyList: $publishers}},
  {provider: "EventHandler", targetType: "SERVICE_DEF", target: "eventSubscription",
   description: "Systems that subscribe to events (callbacks over mutual TLS)",
   defaultPolicy: {policyType: "WHITELIST", policyList: $subscribers}}
]}')

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "EventHandler eventPublish and eventSubscription policies configured"
