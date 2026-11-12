#!/bin/sh
# ConsumerAuthorization policies of the onboarding procedure (Re-running replaces them; scripts/lib-policies.sh).
# Onboarding gets exactly the operations it needs, and nothing else of the management services:
#   CertificateAuthority  certificateSigning (sign on/de/sy certificates), certificateValidation (check-certificate),
#                         certificateAuthorityManagement revoke-certificate (off-boarding; CA allows only its own certificates)
#   Authentication        identityManagement identity-mgmt-create / identity-mgmt-remove (system identities)
#   Blacklist             blacklistManagement create / remove (off-boarded systems; the policy is declared, with its other
#                         consumers, in configure-orchestration-dependency-policies.sh)
# ServiceRegistry management (device-create, device-remove, system-remove) is granted by its MANAGEMENT_WHITELIST in compose.yaml.
set -eu
AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
. "$(dirname -- "$0")/lib-policies.sh"
apply_policies '{"list":[
  {"provider":"CertificateAuthority","targetType":"SERVICE_DEF","target":"certificateSigning","description":"Onboarding has the onboarding, device and system certificates signed; the operations console signs system certificates","defaultPolicy":{"policyType":"WHITELIST","policyList":["Onboarding","Sysop"]},"scopedPolicies":{}},
  {"provider":"CertificateAuthority","targetType":"SERVICE_DEF","target":"certificateValidation","description":"Onboarding checks that onboarding and device certificates are still GOOD","defaultPolicy":{"policyType":"WHITELIST","policyList":["Onboarding","Sysop"]},"scopedPolicies":{}},
  {"provider":"CertificateAuthority","targetType":"SERVICE_DEF","target":"certificateAuthorityManagement","description":"Onboarding revokes the certificates it requested when a device is off-boarded","defaultPolicy":{"policyType":"WHITELIST","policyList":["Sysop"]},"scopedPolicies":{"revoke-certificate":{"policyType":"WHITELIST","policyList":["Onboarding","Sysop"]}}},
  {"provider":"Authentication","targetType":"SERVICE_DEF","target":"identityManagement","description":"Onboarding creates and removes the identities of onboarded systems","defaultPolicy":{"policyType":"WHITELIST","policyList":["Sysop"]},"scopedPolicies":{"identity-mgmt-create":{"policyType":"WHITELIST","policyList":["Onboarding","Sysop"]},"identity-mgmt-remove":{"policyType":"WHITELIST","policyList":["Onboarding","Sysop"]}}}
]}'
echo "Onboarding procedure policies configured"
