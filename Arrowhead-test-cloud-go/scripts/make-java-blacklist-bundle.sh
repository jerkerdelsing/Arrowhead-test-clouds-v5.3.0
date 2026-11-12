#!/bin/sh
# Credential bundles of the Java Blacklist (blacklist-java, 2026-10-24), as TestCloud's Java systems (J7/J15):
#   security/bundles-java/blacklist/     ca.crt (database TLS), keystores/Blacklist.p12 and keystores/truststore.p12,
#                                        protected by the system's own keystore password AH_STORE_PW_BL
#   security/bundles-java/blacklist-db/  ca.crt, server.crt, server.key (TLS of its database)
# Directories 700, files 600 (Docker Desktop lets the containers' users read them). Idempotent.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib-secrets.sh
X509=security/x509
OUT=security/bundles-java
SUFFIX=GoCloud.Company.arrowhead.eu
umask 077
STORE_PASSWORD=$(secret AH_STORE_PW_BL)
mkdir -p "$OUT/blacklist/keystores" "$OUT/blacklist-db"
chmod 700 "$OUT" "$OUT/blacklist" "$OUT/blacklist/keystores" "$OUT/blacklist-db"

cp "$X509/ca.crt" "$OUT/blacklist/ca.crt"
openssl pkcs12 -export -inkey "$X509/blacklist.key" -in "$X509/blacklist.crt" -certfile "$X509/ca.crt" \
  -name "Blacklist.$SUFFIX" -passout "pass:$STORE_PASSWORD" -out "$OUT/blacklist/keystores/Blacklist.p12"
rm -f "$OUT/blacklist/keystores/truststore.p12"
keytool -importcert -noprompt -alias "$SUFFIX" -file "$X509/ca.crt" -storetype PKCS12 \
  -keystore "$OUT/blacklist/keystores/truststore.p12" -storepass "$STORE_PASSWORD" >/dev/null 2>&1

for f in ca.crt server.crt server.key; do cp "$X509/db/blacklist-db/$f" "$OUT/blacklist-db/$f"; done
find "$OUT" -type f -exec chmod 600 {} +
echo "Java Blacklist credential bundles in $OUT"
