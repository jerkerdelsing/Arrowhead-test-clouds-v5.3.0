#!/bin/sh
# CRL of the test manufacturer CA (security finding J4): manufacturer-crl.sh [--revoke <bootstrap-certificate.pem>]
# Onboarding trusts the manufacturer CA for the devices' bootstrap certificates and checks them, fail closed, against
# security/manufacturer-crl/manufacturer-ca.crl, as it checks the cloud's certificates against security/crl/ca.crl.
# A real manufacturer publishes this CRL; here the script stands in for it. Without arguments it (re)issues the CRL when
# it is missing, signed by another key or within RENEW_DAYS of its nextUpdate; --revoke adds a certificate first.
# Onboarding re-reads the CRL within 30 s. Revocation register: security/x509/manufacturer-ca-db.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CERT_DIR="$ROOT_DIR/security/x509"
CA_KEYS="$ROOT_DIR/security/ca"  # the manufacturer CA signing key (J15), see generate-x509.sh
DB_DIR="$CERT_DIR/manufacturer-ca-db"
CRL_DIR="$ROOT_DIR/security/manufacturer-crl"
CRL="$CRL_DIR/manufacturer-ca.crl"
VALID_DAYS=${MANUFACTURER_CRL_DAYS:-365}
RENEW_DAYS=30

revoke=
if [ $# -eq 2 ] && [ "$1" = --revoke ] && [ -f "$2" ]; then
  revoke=$2
elif [ $# -ne 0 ]; then
  echo "usage: $0 [--revoke <bootstrap-certificate.pem>]" >&2
  exit 2
fi

umask 077
mkdir -p "$DB_DIR" "$CRL_DIR"
chmod 755 "$CRL_DIR"
[ -f "$DB_DIR/index.txt" ] || : > "$DB_DIR/index.txt"
[ -f "$DB_DIR/crlnumber" ] || echo 01 > "$DB_DIR/crlnumber"
printf '[ca]\ndefault_ca=c\n[c]\ndatabase=%s/index.txt\ncrlnumber=%s/crlnumber\ndefault_md=sha256\ndefault_crl_days=%s\n' \
  "$DB_DIR" "$DB_DIR" "$VALID_DAYS" > "$DB_DIR/ca.cnf"

if [ -n "$revoke" ]; then
  openssl ca -config "$DB_DIR/ca.cnf" -keyfile "$CA_KEYS/manufacturer-ca.key" -cert "$CERT_DIR/manufacturer-ca.crt" \
    -revoke "$revoke" 2>/dev/null
  echo "Revoked $(openssl x509 -in "$revoke" -noout -subject -serial | tr '\n' ' ')"
elif openssl crl -in "$CRL" -CAfile "$CERT_DIR/manufacturer-ca.crt" -noout >/dev/null 2>&1 \
  && next=$(openssl crl -in "$CRL" -noout -nextupdate | cut -d= -f2) \
  && [ "$(date -j -f '%b %e %T %Y %Z' "$next" +%s 2>/dev/null || date -d "$next" +%s)" -gt "$(( $(date +%s) + RENEW_DAYS * 86400 ))" ]; then
  exit 0
fi

# written next to the target and renamed: Onboarding never reads a partial file
openssl ca -config "$DB_DIR/ca.cnf" -gencrl -keyfile "$CA_KEYS/manufacturer-ca.key" -cert "$CERT_DIR/manufacturer-ca.crt" \
  -out "$CRL.tmp" 2>/dev/null
chmod 644 "$CRL.tmp"
mv "$CRL.tmp" "$CRL"
echo "Manufacturer CRL written to $CRL (valid $VALID_DAYS days)"
