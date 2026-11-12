#!/bin/sh
# Revokes a certificate of this cloud's CA (security finding H3): revoke-certificate.sh <certificate.pem>
# Works for every certificate of the cloud CA, also those issued by generate-x509.sh rather than through the
# CertificateAuthority's sign operation (certificateAuthorityManagement revoke-certificate-by-content, as Sysop).
# The CertificateAuthority rewrites security/crl/ca.crl at once; the MQTT broker and the relay reload it within
# CRL_POLL_SECONDS (10 s), the AMQP broker reads it on the next connection. Existing connections are not cut.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: $0 <certificate.pem>" >&2; exit 2; }
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
