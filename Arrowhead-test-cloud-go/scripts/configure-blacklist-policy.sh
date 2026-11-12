#!/bin/sh
# ConsumerAuthorization policy for the Blacklist check (security finding J12; re-running replaces it; scripts/lib-policies.sh).
# The Go Blacklist enforces authorization on blacklistDiscovery, so the systems that filter their requesters through it
# (ServiceRegistry, ConsumerAuthorization, both orchestrators, TranslationManager, DeviceQoSEvaluator) are granted
# exactly the check operation. Without it every check is refused and, fail closed, so is every non-core requester.
set -eu
AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:7445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:7444}
CERT_DIR=${CERT_DIR:-security/x509}
. "$(dirname -- "$0")/lib-policies.sh"
apply_policies '{"list":[
  {"provider":"Blacklist","targetType":"SERVICE_DEF","target":"blacklistDiscovery","description":"The systems with a Blacklist filter check their requesters","defaultPolicy":{"policyType":"WHITELIST","policyList":["Sysop"]},"scopedPolicies":{"check":{"policyType":"WHITELIST","policyList":["ServiceRegistry","ConsumerAuthorization","DynamicServiceOrchestration","SimpleStoreServiceOrchestration","TranslationManager","DeviceQoSEvaluator","Sysop"]}}}
]}'
echo "Blacklist check policy configured"
