#!/bin/sh
# Re-running replaces the policies (scripts/lib-policies.sh).
#
# The Java core and support systems (ah5-core-java-spring, ah5-support-java-spring) call no other system at a configured
# address. Only the ServiceRegistry is configured; Authentication (identity) and the orchestrator (serviceOrchestration) are
# looked up there, and every other service is consumed through an orchestration request
# (common library http.collector.mode=ORCHESTRATION, JavaSupportRuntime/AIGym/LocalCloudManager consume()).
# DynamicServiceOrchestration returns a provider only when ConsumerAuthorization grants the requesting system the
# service operation, so every dependency is declared here, per operation, as the consumers need it:
#
#   ConsumerAuthorization authorization verify           providers and management filters (management.policy=authorization)
#   ConsumerAuthorization authorizationManagement        Gatekeeper check-policies (inter-cloud consumers), TranslationManager
#                                                        check-policies, LocalCloudManager query-policies (console, read only)
#   ConsumerAuthorization authorizationTokenManagement   TranslationManager generate-tokens
#   Blacklist blacklistDiscovery check                   the blacklist filter of every system (ENABLE_BLACKLIST_FILTER)
#   Blacklist blacklistManagement                        Onboarding create/remove (off-boarding), TranslationManager query
#   SimpleStore / DSO / SysMonitor / PDE / RandomDataProducer management and status services of the console
#   TranslationManager translationBridgeManagement       DynamicServiceOrchestration (translation, when enabled)
#
# DynamicServiceOrchestration itself looks up ConsumerAuthorization's and Blacklist's services in the ServiceRegistry
# (HTTP_COLLECTOR_BOOTSTRAP_SERVICES in compose.yaml): it cannot orchestrate what its own orchestration process calls.
# The scoped policies grant exactly the operations used; where a provider's management filter uses
# management.policy=authorization they are also the management rights (none beyond what the systems used before).
set -eu

AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}

# the systems that verify callers with ConsumerAuthorization: management.policy=authorization, their own provider checks
VERIFIERS='["Authentication","ConsumerAuthorization","Blacklist","TranslationManager","DeviceQoSEvaluator","DataManager","GraphDBManager","TimeManager","EventHandler","PlantDescriptionEngine","Configuration","SysMonitor","AIGym","LocalCloudConfigurator","SoLocalCloudConfigurator"]'
# the systems with ENABLE_BLACKLIST_FILTER (compose.yaml) except ServiceRegistry (own database) and DSO (looks Blacklist up)
BLACKLIST_CHECKERS='["ConsumerAuthorization","SimpleStoreServiceOrchestration","TranslationManager","DeviceQoSEvaluator"]'

. "$(dirname -- "$0")/lib-policies.sh"
apply_policies "$(jq -cn --argjson verifiers "$VERIFIERS" --argjson checkers "$BLACKLIST_CHECKERS" '{list: [
  {provider: "ConsumerAuthorization", targetType: "SERVICE_DEF", target: "authorization",
   description: "Providers verify their consumers (orchestrated authorization.verify)",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["Sysop"]},
   scopedPolicies: {"verify": {policyType: "WHITELIST", policyList: $verifiers}}},
  {provider: "ConsumerAuthorization", targetType: "SERVICE_DEF", target: "authorizationManagement",
   description: "Gatekeeper checks inter-cloud consumers, TranslationManager checks bridges, the console reads the policies",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["Sysop"]},
   scopedPolicies: {"check-policies": {policyType: "WHITELIST", policyList: ["Gatekeeper", "TranslationManager"]},
                    "query-policies": {policyType: "WHITELIST", policyList: ["LocalCloudManager"]}}},
  {provider: "ConsumerAuthorization", targetType: "SERVICE_DEF", target: "authorizationTokenManagement",
   description: "TranslationManager generates the tokens of translation bridges",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["Sysop"]},
   scopedPolicies: {"generate-tokens": {policyType: "WHITELIST", policyList: ["TranslationManager"]}}},
  {provider: "Blacklist", targetType: "SERVICE_DEF", target: "blacklistDiscovery",
   description: "The blacklist filter of every system checks its callers",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["Sysop"]},
   scopedPolicies: {"check": {policyType: "WHITELIST", policyList: $checkers}}},
  {provider: "Blacklist", targetType: "SERVICE_DEF", target: "blacklistManagement",
   description: "Onboarding blacklists off-boarded systems and lifts it on re-approval; TranslationManager queries the blacklist",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["Sysop"]},
   scopedPolicies: {"create": {policyType: "WHITELIST", policyList: ["Onboarding", "Sysop"]},
                    "remove": {policyType: "WHITELIST", policyList: ["Onboarding", "Sysop"]},
                    "query": {policyType: "WHITELIST", policyList: ["TranslationManager", "Sysop"]}}},
  {provider: "SimpleStoreServiceOrchestration", targetType: "SERVICE_DEF", target: "serviceOrchestrationSimpleStoreManagement",
   description: "The console optionally manages SimpleStore rules",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["LocalCloudManager"]}, scopedPolicies: {}},
  {provider: "DynamicServiceOrchestration", targetType: "SERVICE_DEF", target: "serviceOrchestrationPlantManagement",
   description: "PDE replaces the active plant snapshot; the console reads it",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["Sysop"]},
   scopedPolicies: {"query": {policyType: "WHITELIST", policyList: ["PlantDescriptionEngine", "LocalCloudManager", "Sysop"]},
                    "replace": {policyType: "WHITELIST", policyList: ["PlantDescriptionEngine", "Sysop"]}}},
  {provider: "DynamicServiceOrchestration", targetType: "SERVICE_DEF", target: "serviceOrchestrationHistoryManagement",
   description: "The console shows the orchestration history",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["LocalCloudManager"]}, scopedPolicies: {}},
  {provider: "SysMonitor", targetType: "SERVICE_DEF", target: "sysMonitorManagement",
   description: "The console manages the sysMonitor subscriptions",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["LocalCloudManager"]}, scopedPolicies: {}},
  {provider: "PlantDescriptionEngine", targetType: "SERVICE_DEF", target: "plantDescriptionManagement",
   description: "The console edits the plant descriptions",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["LocalCloudManager"]}, scopedPolicies: {}},
  {provider: "RandomDataProducer", targetType: "SERVICE_DEF", target: "randomNumberProducer",
   description: "The console shows the latest value and inter-cloud publishing of the producer",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["LocalCloudManager"]}, scopedPolicies: {}},
  {provider: "TranslationManager", targetType: "SERVICE_DEF", target: "translationBridgeManagement",
   description: "DynamicServiceOrchestration negotiates translation bridges",
   defaultPolicy: {policyType: "WHITELIST", policyList: ["DynamicServiceOrchestration"]}, scopedPolicies: {}}
]}')"
echo "Orchestration dependency policies configured"
