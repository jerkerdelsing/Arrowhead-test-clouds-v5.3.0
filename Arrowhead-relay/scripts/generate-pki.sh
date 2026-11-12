#!/bin/sh
# SPDX-License-Identifier: EPL-2.0
# Test PKI of the relay (security/, not in git). Idempotent: existing files are kept; --force regenerates everything.
#   relay-ca.crt/.key, relay-ca.crl   organisation CA of this relay (Relay test CA, Company), and its CRL (90 days)
#   relay.crt/.key                    relay server certificate, DNS arrowhead-relay and localhost, IP 127.0.0.1
#   trust.pem                         what the broker trusts: relay-ca.crt plus the organisation CA of the GateTunnel
#                                     AH-GT-1 test fixtures (GATETUNNEL_FIXTURES), whose relay identities are committed there
#   clients/gatekeeper/               ca.crt and the identities a and b of the Gatekeeper RelayRoundTripIT
#   clients/gatetunnel/               ca bundle (fixture org CA + relay CA) and the relay CA's CRL for RelayRoundTripTest
# Test keys only: never use them for a cloud.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
S="$HERE/security"
FIXTURES=${GATETUNNEL_FIXTURES:-$HERE/../../Eclipse-Arrowhead-java/ah5-GateTunnel-java-spring/src/test/resources/ahgt1}
[ "${1:-}" = "--force" ] && rm -rf "$S"
mkdir -p "$S/clients/gatekeeper" "$S/clients/gatetunnel" "$S/ca-db"
umask 077
cd "$S"

if [ ! -f relay-ca.key ]; then
	openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out relay-ca.key
	openssl req -x509 -new -key relay-ca.key -sha256 -days 825 -subj "/C=SE/O=Company/CN=Relay test CA.Company.arrowhead.eu" \
		-addext "basicConstraints=critical,CA:true" -addext "keyUsage=critical,keyCertSign,cRLSign" -out relay-ca.crt
	: > ca-db/index.txt
	echo 1000 > ca-db/crlnumber
fi

cat > ca-db/openssl.cnf <<CNF
[ ca ]
default_ca = relay
[ relay ]
database = $S/ca-db/index.txt
crlnumber = $S/ca-db/crlnumber
certificate = $S/relay-ca.crt
private_key = $S/relay-ca.key
default_md = sha256
default_crl_days = 90
CNF

issue() { # name subject extensions
	[ -f "$1.crt" ] && return 0
	openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$1.key"
	openssl req -new -key "$1.key" -subj "$2" -out "$1.csr"
	printf '%s\n' "$3" > "$1.ext"
	openssl x509 -req -in "$1.csr" -CA relay-ca.crt -CAkey relay-ca.key -CAcreateserial -days 365 -sha256 -extfile "$1.ext" -out "$1.crt"
	rm -f "$1.csr" "$1.ext"
}

issue relay "/C=SE/O=Company/CN=Relay.Company.arrowhead.eu" \
	"basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:arrowhead-relay,DNS:localhost,IP:127.0.0.1"
for pair in a:TestCloud b:OtherCloud; do
	id=${pair%%:*} cloud=${pair#*:}
	issue "clients/gatekeeper/$id" "/C=SE/O=Company/OU=$cloud/CN=Gatekeeper.$cloud.Company.arrowhead.eu" \
		"basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth"
done

openssl ca -config ca-db/openssl.cnf -gencrl -out relay-ca.crl 2> /dev/null
cp relay-ca.crt clients/gatekeeper/ca.crt
cat relay-ca.crt "$FIXTURES/org-ca.crt" > trust.pem
cat "$FIXTURES/org-ca.crt" relay-ca.crt > clients/gatetunnel/ca-bundle.crt
cp relay-ca.crl clients/gatetunnel/relay-ca.crl
chmod 644 relay.crt relay.key trust.pem # read by the broker's user (1883) through the bind mount
openssl verify -CAfile relay-ca.crt relay.crt clients/gatekeeper/a.crt clients/gatekeeper/b.crt
for cloud in TestCloud GoCloud; do
	openssl verify -CAfile "$FIXTURES/org-ca.crt" -untrusted "$FIXTURES/$cloud-relay-chain.crt" "$FIXTURES/$cloud-relay-chain.crt"
done
openssl crl -in relay-ca.crl -noout -nextupdate
