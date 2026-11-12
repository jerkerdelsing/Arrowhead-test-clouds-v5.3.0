#!/bin/sh
# Re-running replaces the policies (scripts/lib-policies.sh).
# ConsumerAuthorization policies of the translation bridge (2026-10-24):
#   - TranslationManager uses TestTranslation's interfaceBridgeManagement (check-targets, initialize-bridge,
#     abort-bridge); TestTranslation, as interface translator, uses its own dataModelTranslation;
#   - TestTranslation reports bridge events to the TranslationManager (translationReport);
#   - DynamicServiceOrchestration discovers and negotiates bridges for consumers that allow translation
#     (translationBridgeManagement; consumers never call the TranslationManager themselves).
# TestTranslation reading DataManager data for its bridges is granted in configure-datamanager-policies.sh.
set -eu

AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:7445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:7444}
CERT_DIR=${CERT_DIR:-security/x509}
PAYLOAD='{"list":[
  {"provider":"TestTranslation","targetType":"SERVICE_DEF","target":"interfaceBridgeManagement","description":"TranslationManager initializes and aborts translation bridges","defaultPolicy":{"policyType":"WHITELIST","policyList":["TranslationManager"]}},
  {"provider":"TestTranslation","targetType":"SERVICE_DEF","target":"dataModelTranslation","description":"The interface translator of a bridge translates payloads","defaultPolicy":{"policyType":"WHITELIST","policyList":["TestTranslation"]}},
  {"provider":"TranslationManager","targetType":"SERVICE_DEF","target":"translationReport","description":"Interface translators report bridge usage, closing and errors","defaultPolicy":{"policyType":"WHITELIST","policyList":["TestTranslation"]}},
  {"provider":"TranslationManager","targetType":"SERVICE_DEF","target":"translationBridgeManagement","description":"DynamicServiceOrchestration builds translation bridges (ALLOW_TRANSLATION)","defaultPolicy":{"policyType":"WHITELIST","policyList":["DynamicServiceOrchestration"]}}
]}'

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$PAYLOAD"
echo "TranslationManager/TestTranslation translation bridge policies configured"

# The TranslationManager checks candidates and translators with authorizationManagement.check-policies. That policy
# belongs to configure-intercloud.sh (one policy per provider/service); merge the scope grant, keeping everything else.
policy_token
existing=$(policy_call --data '{"providers":["ConsumerAuthorization"],"targetNames":["authorizationManagement"],"level":"MGMT"}' "$AUTHORIZATION_URL/consumerauthorization/authorization/mgmt/query")
payload=$(jq -cn --argjson existing "$existing" '
  (($existing.entries // []) | map(select(.provider == "ConsumerAuthorization" and .target == "authorizationManagement" and (.cloud // "LOCAL") == "LOCAL" and .level == "MGMT")) | .[0]) as $old
  | ($old.scopedPolicies["check-policies"] // {policyType:"WHITELIST",policyList:["Gatekeeper"]}) as $check
  | if $check.policyType != "WHITELIST" then error("check-policies is not a whitelist; existing policy retained") else . end
  | {list:[{provider:"ConsumerAuthorization",targetType:"SERVICE_DEF",target:"authorizationManagement",
      description:($old.description // "Gatekeeper checks inter-cloud consumers"),
      defaultPolicy:($old.defaultPolicy // {policyType:"WHITELIST",policyList:["Sysop"]}),
      scopedPolicies:(($old.scopedPolicies // {}) + {"check-policies": ($check | .policyList = ((.policyList + ["TranslationManager"]) | unique))})}]}')
apply_policies "$payload"
echo "TranslationManager authorization check grant merged"
