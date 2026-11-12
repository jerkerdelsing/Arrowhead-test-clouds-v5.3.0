#!/bin/sh
# Re-running replaces the policies (scripts/lib-policies.sh).
# ConsumerAuthorization policy for LocalCloudConfigurator's localCloudConfiguration service. The operations console
# (LocalCloudManager, LC view) reaches it only through orchestration, so DynamicServiceOrchestration returns the provider
# only for granted operations, and LocalCloudConfigurator checks every call again (authorization.verify; it is listed in
# VERIFIERS of configure-orchestration-dependency-policies.sh). Only Sysop has the default policy; LocalCloudManager gets
# exactly the operations of the LC editor, including plan and submit-deployment (a reviewed deployment starts or stops
# catalogued components through the host worker; the console requires its session and an action confirmation).
# 2026-11-11: SoLocalCloudConfigurator reads the stored designs to compose Systems of LocalClouds (SoLC view): catalog,
# list-configurations and get-configuration only; it can neither change a design nor plan or apply a deployment.
set -eu

AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
CONSOLE='{"policyType":"WHITELIST","policyList":["LocalCloudManager"]}'
READERS='{"policyType":"WHITELIST","policyList":["LocalCloudManager","SoLocalCloudConfigurator"]}'
READ_OPERATIONS="catalog list-configurations get-configuration"
OPERATIONS="catalog status list-configurations get-configuration create-configuration update-configuration remove-configuration plan submit-deployment get-deployment"

PAYLOAD=$(jq -cn --argjson console "$CONSOLE" --argjson readers "$READERS" --arg operations "$OPERATIONS" --arg reads "$READ_OPERATIONS" '{list: [
  {provider: "LocalCloudConfigurator", targetType: "SERVICE_DEF", target: "localCloudConfiguration",
   description: "The operations console designs, reviews and applies the local cloud configuration (LC view)",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["Sysop"]},
   scopedPolicies: (($operations | split(" ") | map({key: ., value: $console}) | from_entries)
                    + ($reads | split(" ") | map({key: ., value: $readers}) | from_entries))}
]}')

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "LocalCloudConfigurator localCloudConfiguration policies configured"
