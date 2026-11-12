#!/bin/sh
# Re-running replaces the policies (scripts/lib-policies.sh).
# ConsumerAuthorization policy for SoLocalCloudConfigurator's soLocalCloudConfiguration service (2026-11-11). The operations
# console (LocalCloudManager, SoLC view) reaches it only through orchestration, so DynamicServiceOrchestration returns the
# provider only for granted operations, and SoLocalCloudConfigurator checks every call again (authorization.verify; it is
# listed in VERIFIERS of configure-orchestration-dependency-policies.sh). Only Sysop has the default policy; LocalCloudManager
# gets exactly the operations of the SoLC editor. SoLocalCloudConfigurator's own read access to the stored local-cloud
# designs is part of configure-localcloudconfigurator-policy.sh (one policy per provider and service).
set -eu

AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
CONSOLE='{"policyType":"WHITELIST","policyList":["LocalCloudManager"]}'
OPERATIONS="catalog list-lc-designs list-designs get-design create-design update-design remove-design plan build-package list-packages get-package remove-package"

PAYLOAD=$(jq -cn --argjson console "$CONSOLE" --arg operations "$OPERATIONS" '{list: [
  {provider: "SoLocalCloudConfigurator", targetType: "SERVICE_DEF", target: "soLocalCloudConfiguration",
   description: "The operations console designs Systems of LocalClouds and builds their deployment packages (SoLC view)",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["Sysop"]},
   scopedPolicies: ($operations | split(" ") | map({key: ., value: $console}) | from_entries)}
]}')

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "SoLocalCloudConfigurator soLocalCloudConfiguration policies configured"
