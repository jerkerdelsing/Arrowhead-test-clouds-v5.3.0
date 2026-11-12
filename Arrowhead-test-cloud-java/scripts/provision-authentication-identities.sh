#!/bin/sh
set -eu
. "$(dirname -- "$0")/lib-secrets.sh"
_require_secret=$(secret AH_PW_BL)
_require_secret=$(secret AH_PW_CA)
_require_secret=$(secret AH_PW_CAU)
_require_secret=$(secret AH_PW_CFG)
_require_secret=$(secret AH_PW_CHO)
_require_secret=$(secret AH_PW_DM)
_require_secret=$(secret AH_PW_GDM)
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

AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
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
identities="[
{\"systemName\":\"DynamicServiceOrchestration\",\"credentials\":{\"password\":\"$(secret AH_PW_DSO)\"},\"sysop\":false},
  {\"systemName\":\"SimpleStoreServiceOrchestration\",\"credentials\":{\"password\":\"$(secret AH_PW_SSO)\"},\"sysop\":false},
  {\"systemName\":\"ConsumerAuthorization\",\"credentials\":{\"password\":\"$(secret AH_PW_CA)\"},\"sysop\":false},
  {\"systemName\":\"Blacklist\",\"credentials\":{\"password\":\"$(secret AH_PW_BL)\"},\"sysop\":false},
  {\"systemName\":\"TranslationManager\",\"credentials\":{\"password\":\"$(secret AH_PW_TM)\"},\"sysop\":false},
  {\"systemName\":\"DeviceQoSEvaluator\",\"credentials\":{\"password\":\"$(secret AH_PW_DQE)\"},\"sysop\":false},
  {\"systemName\":\"DataManager\",\"credentials\":{\"password\":\"$(secret AH_PW_DM)\"},\"sysop\":false},
  {\"systemName\":\"GraphDBManager\",\"credentials\":{\"password\":\"$(secret AH_PW_GDM)\"},\"sysop\":false},
  {\"systemName\":\"TimeManager\",\"credentials\":{\"password\":\"$(secret AH_PW_TMG)\"},\"sysop\":false},
  {\"systemName\":\"Configuration\",\"credentials\":{\"password\":\"$(secret AH_PW_CFG)\"},\"sysop\":false},
  {\"systemName\":\"Choreographer\",\"credentials\":{\"password\":\"$(secret AH_PW_CHO)\"},\"sysop\":false},
  {\"systemName\":\"RandomDataProducer\",\"credentials\":{\"password\":\"$(secret AH_PW_RDP)\"},\"sysop\":false},
  {\"systemName\":\"SysMonitor\",\"credentials\":{\"password\":\"$(secret AH_PW_SM)\"},\"sysop\":false},
  {\"systemName\":\"EventHandler\",\"credentials\":{\"password\":\"$(secret AH_PW_EH)\"},\"sysop\":false},
  {\"systemName\":\"ServiceRegistry\",\"credentials\":{\"password\":\"$(secret AH_PW_SR)\"},\"sysop\":false},
  {\"systemName\":\"Onboarding\",\"credentials\":{\"password\":\"$(secret AH_PW_ONB)\"},\"sysop\":false},
  {\"systemName\":\"CertificateAuthority\",\"credentials\":{\"password\":\"$(secret AH_PW_CAU)\"},\"sysop\":false},
  {\"systemName\":\"LocalCloudManager\",\"credentials\":{\"password\":\"$(secret AH_PW_LCM)\"},\"sysop\":false}
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
  # Java names the system in its message; the native cores answer 409 "Identity already exists"
  elif printf '%s' "$response" | jq -e --arg n "$name" '(.errorMessage? // "" | test("already exist") and contains($n)) or .errorCode? == 409' >/dev/null 2>&1; then
    existing=$((existing + 1))
  else
    echo "Unable to provision the $name identity: $response" >&2
    exit 1
  fi
done
echo "Authentication identities provisioned: $created created, $existing already existed"

# J23: only Sysop is a sysop. The console identity LocalCloudManager was created as a sysop before 2026-10-21, which let
# it pass every management filter; its rights are now the explicit grants (management whitelists and ConsumerAuthorization
# policies). Clear the flag on an existing identity too. The update ends LocalCloudManager's sessions; the console logs
# in again on its next call.
lcm_update=$(printf '{"identities":[{"systemName":"LocalCloudManager","credentials":{"password":"%s"},"sysop":false}]}' "$(secret AH_PW_LCM)" |
  curl -sS --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/sysop.crt" --key "$CERT_DIR/sysop.key" -X PUT \
    -H "Authorization: Bearer IDENTITY-TOKEN//$token" -H 'Content-Type: application/json' --data-binary @- \
    "$AUTHENTICATION_URL/authentication/mgmt/identities")
if printf '%s' "$lcm_update" | jq -e '.identities? // .entries? // [] | any(.systemName == "LocalCloudManager" and .sysop == false)' >/dev/null 2>&1; then
  echo "LocalCloudManager is not a sysop"
else
  echo "Unable to clear the sysop flag of LocalCloudManager: $(printf '%s' "$lcm_update" | jq -c '.errorMessage? // .' 2>/dev/null | cut -c1-200)" >&2
  exit 1
fi

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

# J23 also for ServiceRegistry, which Authentication seeds as a sysop. Only when the flag is set: the update ends the
# registry's own session, so ServiceRegistry is restarted to log in again.
sr_sysop=$(curl -sS --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/sysop.crt" --key "$CERT_DIR/sysop.key" \
    -H "Authorization: Bearer IDENTITY-TOKEN//$token" -H 'Content-Type: application/json' \
    --data '{"pagination":{"page":0,"size":1000}}' "$AUTHENTICATION_URL/authentication/mgmt/identities/query" |
  jq -r '[(.identities // .entries // [])[] | select(.systemName == "ServiceRegistry") | .sysop | tostring] | first // "unknown"')
if [ "$sr_sysop" = true ]; then
  sr_update=$(printf '{"identities":[{"systemName":"ServiceRegistry","credentials":{"password":"%s"},"sysop":false}]}' "$SR_PASSWORD" |
    curl -sS --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/sysop.crt" --key "$CERT_DIR/sysop.key" -X PUT \
      -H "Authorization: Bearer IDENTITY-TOKEN//$token" -H 'Content-Type: application/json' --data-binary @- \
      "$AUTHENTICATION_URL/authentication/mgmt/identities")
  if printf '%s' "$sr_update" | jq -e '.identities? // .entries? // [] | any(.systemName == "ServiceRegistry" and .sysop == false)' >/dev/null 2>&1; then
    docker compose restart serviceregistry >/dev/null 2>&1
    echo "ServiceRegistry is no longer a sysop (restarted)"
  else
    echo "Unable to clear the sysop flag of ServiceRegistry: $(printf '%s' "$sr_update" | jq -c '.errorMessage? // .' 2>/dev/null | cut -c1-200)" >&2
    exit 1
  fi
else
  echo "ServiceRegistry is not a sysop"
fi
