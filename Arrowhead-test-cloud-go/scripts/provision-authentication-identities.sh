#!/bin/sh
set -eu
. "$(dirname -- "$0")/lib-secrets.sh"
_require_secret=$(secret AH_PW_BL)
_require_secret=$(secret AH_PW_CA)
_require_secret=$(secret AH_PW_CAU)
_require_secret=$(secret AH_PW_CFG)
_require_secret=$(secret AH_PW_CHO)
_require_secret=$(secret AH_PW_DM)
_require_secret=$(secret AH_PW_DQE)
_require_secret=$(secret AH_PW_DSO)
_require_secret=$(secret AH_PW_EH)
_require_secret=$(secret AH_PW_LCM)
_require_secret=$(secret AH_PW_ONB)
_require_secret=$(secret AH_PW_RDP)
_require_secret=$(secret AH_PW_SM)
_require_secret=$(secret AH_PW_SR)
_require_secret=$(secret AH_PW_SSO)
_require_secret=$(secret AH_PW_TM)
_require_secret=$(secret AH_PW_TMG)
_require_secret=$(secret ARROWHEAD_SYSOP_PASSWORD)

AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:7444}
CERT_DIR=${CERT_DIR:-security/x509}
SYSOP_PASSWORD=$(secret ARROWHEAD_SYSOP_PASSWORD)

# Authentication creates Sysop at its first start with the upstream default password. Replace it with this cloud's
# secret (H2): identity/change bound to sysop.crt, no login. Afterwards the default is refused (401), so this is
# idempotent; scripts/rotate-secrets.sh apply does the same for a running cloud.
sysop_default_replaced() {
  curl -s -o /dev/null --max-time 10 --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/sysop.crt" --key "$CERT_DIR/sysop.key" \
    -H 'Content-Type: application/json' \
    --data "{\"systemName\":\"Sysop\",\"credentials\":{\"password\":\"xFNHbh2mQyIp1gmimeTC\"},\"newCredentials\":{\"password\":\"$SYSOP_PASSWORD\"}}" \
    "$AUTHENTICATION_URL/authentication/identity/change" || true
}

# Authentication has no Docker health check and may restart once while ServiceRegistry settles: wait for it.
attempt=0
until sysop_default_replaced; token=$(curl -fsS --max-time 10 --cacert "$CERT_DIR/ca.crt" \
  --cert "$CERT_DIR/sysop.crt" \
  --key "$CERT_DIR/sysop.key" \
  -H 'Content-Type: application/json' \
  --data "{\"systemName\":\"Sysop\",\"credentials\":{\"password\":\"$SYSOP_PASSWORD\"}}" \
  "$AUTHENTICATION_URL/authentication/identity/login" 2>/dev/null | jq -er '.token' 2>/dev/null); do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    echo "Authentication did not accept the Sysop login within 5 minutes" >&2
    exit 1
  fi
  sleep 5
done

# One identity per request: Authentication rejects a whole batch when any of its systems already exists.
# An existing identity is left unchanged (its password is not reset), so re-running is safe.
# The native Go Authentication registers its own services and needs its own identity for that (2026-10-17).
AUTHENTICATION_IDENTITY=""
if [ -n "$(sed -n 's/^AH_PW_AUTH=//p' .env 2>/dev/null)" ]; then
  AUTHENTICATION_IDENTITY=",
  {\"systemName\":\"Authentication\",\"credentials\":{\"password\":\"$(secret AH_PW_AUTH)\"},\"sysop\":false}"
fi
identities="[
{\"systemName\":\"DynamicServiceOrchestration\",\"credentials\":{\"password\":\"$(secret AH_PW_DSO)\"},\"sysop\":false},
  {\"systemName\":\"SimpleStoreServiceOrchestration\",\"credentials\":{\"password\":\"$(secret AH_PW_SSO)\"},\"sysop\":false},
  {\"systemName\":\"ConsumerAuthorization\",\"credentials\":{\"password\":\"$(secret AH_PW_CA)\"},\"sysop\":false},
  {\"systemName\":\"Blacklist\",\"credentials\":{\"password\":\"$(secret AH_PW_BL)\"},\"sysop\":false},
  {\"systemName\":\"TranslationManager\",\"credentials\":{\"password\":\"$(secret AH_PW_TM)\"},\"sysop\":false},
  {\"systemName\":\"TestTranslation\",\"credentials\":{\"password\":\"$(secret AH_PW_TT)\"},\"sysop\":false},
  {\"systemName\":\"DeviceQoSEvaluator\",\"credentials\":{\"password\":\"$(secret AH_PW_DQE)\"},\"sysop\":false},
  {\"systemName\":\"DataManager\",\"credentials\":{\"password\":\"$(secret AH_PW_DM)\"},\"sysop\":false},
  {\"systemName\":\"TimeManager\",\"credentials\":{\"password\":\"$(secret AH_PW_TMG)\"},\"sysop\":false},
  {\"systemName\":\"Configuration\",\"credentials\":{\"password\":\"$(secret AH_PW_CFG)\"},\"sysop\":false},
  {\"systemName\":\"Choreographer\",\"credentials\":{\"password\":\"$(secret AH_PW_CHO)\"},\"sysop\":false},
  {\"systemName\":\"RandomDataProducer\",\"credentials\":{\"password\":\"$(secret AH_PW_RDP)\"},\"sysop\":false},
  {\"systemName\":\"SysMonitor\",\"credentials\":{\"password\":\"$(secret AH_PW_SM)\"},\"sysop\":false},
  {\"systemName\":\"EventHandler\",\"credentials\":{\"password\":\"$(secret AH_PW_EH)\"},\"sysop\":false},
  {\"systemName\":\"ServiceRegistry\",\"credentials\":{\"password\":\"$(secret AH_PW_SR)\"},\"sysop\":false},
  {\"systemName\":\"Onboarding\",\"credentials\":{\"password\":\"$(secret AH_PW_ONB)\"},\"sysop\":false},
  {\"systemName\":\"CertificateAuthority\",\"credentials\":{\"password\":\"$(secret AH_PW_CAU)\"},\"sysop\":false},
  {\"systemName\":\"LocalCloudManager\",\"credentials\":{\"password\":\"$(secret AH_PW_LCM)\"},\"sysop\":true}$AUTHENTICATION_IDENTITY
]"

created=0
existing=0
for identity in $(printf '%s' "$identities" | jq -c '.[]'); do
  name=$(printf '%s' "$identity" | jq -r '.systemName')
  response=$(curl -sS --cacert "$CERT_DIR/ca.crt" \
    --cert "$CERT_DIR/sysop.crt" \
    --key "$CERT_DIR/sysop.key" \
    -H "Authorization: Bearer IDENTITY-TOKEN//$token" \
    -H 'Content-Type: application/json' \
    --data "{\"authenticationMethod\":\"PASSWORD\",\"identities\":[$identity]}" \
    "$AUTHENTICATION_URL/authentication/mgmt/identities")
  if printf '%s' "$response" | jq -e --arg n "$name" '.identities? // .entries? // [] | any(.systemName == $n)' >/dev/null 2>&1; then
    created=$((created + 1))
  elif printf '%s' "$response" | jq -e --arg n "$name" '.errorMessage? // "" | test("already exist") and (contains($n) or . == "Identity already exists")' >/dev/null 2>&1; then
    existing=$((existing + 1))
  else
    echo "Unable to provision the $name identity: $response" >&2
    exit 1
  fi
done
echo "Authentication identities provisioned: $created created, $existing already existed"

# Authentication seeds ServiceRegistry with the default password 123456. Rotate it to the configured password,
# as ServiceRegistry itself: credential changes are bound to the caller's client certificate. Idempotent.
SR_PASSWORD=$(secret AH_PW_SR)
sr_curl() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$CERT_DIR/ca.crt" \
    --cert "$CERT_DIR/serviceregistry.crt" --key "$CERT_DIR/serviceregistry.key" -H 'Content-Type: application/json' "$@"
}
# No login check: a login as ServiceRegistry would replace the running registry's own session token.
change_code=$(sr_curl --data "{\"systemName\":\"ServiceRegistry\",\"credentials\":{\"password\":\"123456\"},\"newCredentials\":{\"password\":\"$SR_PASSWORD\"}}" \
  "$AUTHENTICATION_URL/authentication/identity/change")
case "$change_code" in
  200) echo "ServiceRegistry default password replaced by the configured password" ;;
  401) echo "ServiceRegistry identity no longer uses the default password" ;;
  *) echo "Unable to set the ServiceRegistry identity password (HTTP $change_code)" >&2; exit 1 ;;
esac
