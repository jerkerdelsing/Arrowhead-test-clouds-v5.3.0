#!/bin/sh
# Revokes a certificate of this cloud's CA (security findings H3, J4): revoke-certificate.sh <certificate.pem> [--offboard]
# Works for every certificate of the cloud CA, also those issued by generate-x509.sh rather than through the
# CertificateAuthority's sign operation (certificateAuthorityManagement revoke-certificate-by-content, as Sysop).
# The CertificateAuthority rewrites security/crl/ca.crl at once; the MQTT broker and the relay reload it within
# CRL_POLL_SECONDS (10 s), the AMQP broker reads it on the next connection. The HTTPS services re-read it within
# 30 s (J4) and refuse new handshakes with the certificate. Existing connections are not cut.
# --offboard also ends the system's access that does not depend on new handshakes: its Authentication sessions are
# closed (its identity tokens stop working at once) and its identity is removed (no new login). Restart the system's
# container afterwards, or stop it, so that no established connection of it remains.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"
offboard=no
[ "${2:-}" = --offboard ] && offboard=yes
{ [ $# -eq 1 ] || { [ $# -eq 2 ] && [ "$offboard" = yes ]; }; } && [ -f "$1" ] \
  || { echo "usage: $0 <certificate.pem> [--offboard]" >&2; exit 2; }
. "$ROOT_DIR/scripts/registry-auth.sh"
CA_PORT=$(sed -n 's/^CERTIFICATE_AUTHORITY_PORT=//p' .env | tail -n 1)
CA_URL=${CERTIFICATE_AUTHORITY_URL:-https://127.0.0.1:${CA_PORT:-8448}}

serial=$(openssl x509 -in "$1" -noout -serial | sed 's/^serial=//')
sysop_login || { echo "Sysop login failed" >&2; exit 1; }
payload=$(jq -n --rawfile certificate "$1" '{certificate: $certificate}')
response=$(curl -fsS --max-time 15 $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' \
  --data "$payload" "$CA_URL/certificate-authority/mgmt/revocations")
echo "Revoked: $(printf '%s' "$response" | jq -c .)"

attempt=0
until openssl crl -in security/crl/ca.crl -noout -text 2>/dev/null | grep -qi "Serial Number: *$serial"; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 15 ] || { echo "serial $serial not in security/crl/ca.crl after 30 s" >&2; exit 1; }
  sleep 2
done
echo "Serial $serial is in the published CRL"

if [ "$offboard" = yes ]; then
  AUTH_PORT=$(sed -n 's/^AUTHENTICATION_PORT=//p' .env | tail -n 1)
  AUTH_URL=${AUTHENTICATION_URL:-https://127.0.0.1:${AUTH_PORT:-8444}}
  # the system name is the first label of the certificate's common name (<System>.<Cloud>.<Org>.arrowhead.eu)
  system=$(openssl x509 -in "$1" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p' | cut -d. -f1)
  [ -n "$system" ] && [ "$system" != Sysop ] || { echo "no system name to offboard in $1" >&2; exit 1; }
  for target in sessions identities; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 $SYSOP_TLS -H "$SYSOP_AUTH" -X DELETE \
      "$AUTH_URL/authentication/mgmt/$target?names=$system")
    case "$code" in 2??) echo "Authentication $target of $system removed" ;; *) echo "removing the $target of $system: HTTP $code" >&2; exit 1 ;; esac
  done
fi
