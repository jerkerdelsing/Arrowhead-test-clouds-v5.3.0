#!/bin/sh
set -eu
. "$(dirname -- "$0")/lib-secrets.sh"
_require_secret=$(secret AH_PW_SM)
_require_secret=$(secret ARROWHEAD_SYSOP_PASSWORD)

AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
SYSOP_PASSWORD=$(secret ARROWHEAD_SYSOP_PASSWORD)
token=$(curl -fsS --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/sysop.crt" \
  --key "$CERT_DIR/sysop.key" -H 'Content-Type: application/json' \
  --data "{\"systemName\":\"Sysop\",\"credentials\":{\"password\":\"$SYSOP_PASSWORD\"}}" \
  "$AUTHENTICATION_URL/authentication/identity/login" | jq -er '.token')
response=$(curl -sS --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/sysop.crt" \
  --key "$CERT_DIR/sysop.key" -H "Authorization: Bearer IDENTITY-TOKEN//$token" \
  -H 'Content-Type: application/json' \
  --data "{\"authenticationMethod\":\"PASSWORD\",\"identities\":[{\"systemName\":\"SysMonitor\",\"credentials\":{\"password\":\"$(secret AH_PW_SM)\"},\"sysop\":false}]}" \
  "$AUTHENTICATION_URL/authentication/mgmt/identities")
# Exact checks: an error message also names the system, so matching the name alone would hide failures.
if printf '%s' "$response" | jq -e '.identities? // .entries? // [] | any(.systemName == "SysMonitor")' >/dev/null 2>&1; then
  echo "SysMonitor Authentication identity provisioned"
elif printf '%s' "$response" | jq -e '.errorMessage? // "" | test("already exist") and contains("SysMonitor")' >/dev/null 2>&1; then
  echo "SysMonitor Authentication identity already exists"
else
  echo "Unable to provision SysMonitor identity: $response" >&2
  exit 1
fi
