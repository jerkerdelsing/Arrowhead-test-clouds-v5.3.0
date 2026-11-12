#!/bin/sh
# Local PDE/DSO extension, 2026-10-23. SSO remains an independent optional service.
set -eu
cd "$(dirname "$0")/.."
AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:7445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:7444}
CERT_DIR=${CERT_DIR:-security/x509}
SECRETS_ENV_FILE=.env
. ./scripts/lib-secrets.sh
. ./scripts/lib-policies.sh
apply_policies '{"list":[{"provider":"DynamicServiceOrchestration","targetType":"SERVICE_DEF","target":"serviceOrchestrationPlantManagement","description":"PDE manages the DSO snapshot; console reads only","defaultPolicy":{"policyType":"WHITELIST","policyList":["Sysop"]},"scopedPolicies":{"query":{"policyType":"WHITELIST","policyList":["PlantDescriptionEngine","LocalCloudManager","Sysop"]},"replace":{"policyType":"WHITELIST","policyList":["PlantDescriptionEngine","Sysop"]}}}]}'
echo 'PDE/DSO operation policies configured'
# The shared console discovers these existing read panels through DSO. Merge the read grants,
# retaining other clients, scopes and the existing default policy.
policy_token
existing=$(policy_call -H 'Content-Type: application/json' --data '{"providers":["ConsumerAuthorization","DynamicServiceOrchestration","SimpleStoreServiceOrchestration","PlantDescriptionEngine"],"targetNames":["authorizationManagement","serviceOrchestrationHistoryManagement","serviceOrchestrationSimpleStoreManagement","plantDescriptionManagement"],"level":"MGMT"}' "$AUTHORIZATION_URL/consumerauthorization/authorization/mgmt/query")
payload=$(jq -cn --argjson existing "$existing" '
  def allow_console:
    if .policyType == "ALL" then .
    elif .policyType == "BLACKLIST" then .policyList = [(.policyList // [])[] | select(. != "LocalCloudManager")]
    elif .policyType == "WHITELIST" then .policyList = (((.policyList // []) + ["LocalCloudManager"]) | unique)
    else error("Console read policy uses an unsupported merge type; existing policy retained") end;
  {list: ([
    {provider:"ConsumerAuthorization",target:"authorizationManagement",operation:"query-policies"},
    {provider:"DynamicServiceOrchestration",target:"serviceOrchestrationHistoryManagement",operation:"query"},
    {provider:"SimpleStoreServiceOrchestration",target:"serviceOrchestrationSimpleStoreManagement",operation:"query"},
    {provider:"PlantDescriptionEngine",target:"plantDescriptionManagement",operation:"query"}
  ] | map(. as $s | (($existing.entries // []) | map(select(.provider == $s.provider and .target == $s.target and (.cloud // "LOCAL") == "LOCAL" and .level == "MGMT")) | .[0]) as $old |
    {provider:$s.provider,targetType:"SERVICE_DEF",target:$s.target,
     description:($old.description // "Console read access through DSO"),
     defaultPolicy:($old.defaultPolicy // {policyType:"WHITELIST",policyList:["Sysop"]}),
     scopedPolicies:(($old.scopedPolicies // {}) + {($s.operation): (($old.scopedPolicies[$s.operation] // $old.defaultPolicy // {policyType:"WHITELIST",policyList:["Sysop"]}) | allow_console)})}
  ))}')
apply_policies "$payload"
echo 'Console dependency read grants configured'

# Keep the graphical editor operation grants after refreshing console read policies.
sh ./scripts/configure-console-edit-policies.sh
