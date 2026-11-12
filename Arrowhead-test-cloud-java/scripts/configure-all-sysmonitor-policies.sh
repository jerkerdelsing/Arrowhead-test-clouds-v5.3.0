#!/bin/sh
# Owner of every sysMonitor policy: SysMonitor may subscribe to each provider's echo, power and status.
# Other configure-*-policy scripts leave sysMonitor alone. Re-running replaces the policies (scripts/lib-policies.sh).
set -eu
AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}


providers='["ServiceRegistry","DynamicServiceOrchestration","SimpleStoreServiceOrchestration","ConsumerAuthorization","Authentication","Blacklist","TranslationManager","DeviceQoSEvaluator","Onboarding","DataManager","GraphDBManager","TimeManager","EventHandler","PlantDescriptionEngine","Configuration","Choreographer","RandomDataProducer","SysMonitor","Gatekeeper","GateTunnel","AIGym","LocalCloudManager","CertificateAuthority"]'
PAYLOAD=$(jq -cn --argjson providers "$providers" '{list: $providers | map({
  provider: ., targetType: "SERVICE_DEF", target: "sysMonitor",
  description: ("Allow SysMonitor to consume " + . + " observations"),
  defaultPolicy: {policyType: "WHITELIST", policyList: ["SysMonitor"]},
  scopedPolicies: {
    echo: {policyType: "WHITELIST", policyList: ["SysMonitor"]},
    power: {policyType: "WHITELIST", policyList: ["SysMonitor"]},
    status: {policyType: "WHITELIST", policyList: ["SysMonitor"]}
  }
})}')

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "sysMonitor policies configured"
