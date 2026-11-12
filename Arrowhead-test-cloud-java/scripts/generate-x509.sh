#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CERT_DIR="$ROOT_DIR/security/x509"
# Signing keys of the cloud CA, the onboarding CA chain and the test manufacturer CA (security finding J15). They are kept
# apart from the system credentials, so that mounting security/x509 by mistake does not hand out a CA. No container mounts
# security/ca; the cloud CA key reaches the CertificateAuthority only through its credential bundle.
CA_KEYS="$ROOT_DIR/security/ca"
CA_KEY_NAMES="ca manufacturer-ca onboarding-root-ca onboarding-organization-ca onboarding-local-cloud-ca"
# Keystore passwords: one per system (security finding J7), per-cloud secrets AH_STORE_PW_<ABBR> in .env
# (scripts/rotate-secrets.sh), no default (H2). A system's truststore has the same password as its keystore, so a
# leaked password opens only that system's stores.
. "$ROOT_DIR/scripts/lib-secrets.sh"
store_password() { secret "AH_STORE_PW_$1"; }

# Local cloud name: system certificates are <System>.<CLOUD_NAME>.Company.arrowhead.eu, signed by the
# self-signed cloud CA <CLOUD_NAME>.Company.arrowhead.eu. Inter-cloud trust comes from the organization CA
# (../Arrowhead-relay/scripts/generate-org-pki.sh), which cross-signs this cloud CA.
CLOUD_NAME=${ARROWHEAD_CLOUD_NAME:-TestCloud}

# Material issued for another cloud name is moved aside (not deleted) and everything is issued anew.
if [ -f "$CERT_DIR/ca.crt" ] && ! openssl x509 -in "$CERT_DIR/ca.crt" -noout -subject | grep -q "CN *= *$CLOUD_NAME.Company.arrowhead.eu"; then
  old_cn=$(openssl x509 -in "$CERT_DIR/ca.crt" -noout -subject | sed -n 's/.*CN *= *\([^.,]*\).*/\1/p')
  backup="$ROOT_DIR/security/x509.${old_cn:-old}-backup"
  rm -rf "$backup"
  mv "$CERT_DIR" "$backup"
  [ -d "$CA_KEYS" ] && mv "$CA_KEYS" "$backup/ca-keys"
  echo "Moved X.509 material of cloud ${old_cn:-?} to $backup; issuing $CLOUD_NAME material"
fi

umask 077
mkdir -p "$CERT_DIR" "$CA_KEYS"
chmod 700 "$CA_KEYS"
# CA keys issued before J15 lived in security/x509: move them (never copy, so that exactly one working copy remains)
for name in $CA_KEY_NAMES; do
  if [ -f "$CERT_DIR/$name.key" ]; then
    if [ -f "$CA_KEYS/$name.key" ]; then
      echo "generate-x509: $name.key exists in both security/x509 and security/ca; remove the stale one" >&2; exit 1
    fi
    mv "$CERT_DIR/$name.key" "$CA_KEYS/$name.key"
    echo "Moved $name.key to security/ca (J15)"
  fi
done

if [ ! -f "$CA_KEYS/ca.key" ] || [ ! -f "$CERT_DIR/ca.crt" ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$CA_KEYS/ca.key"
  openssl req -x509 -new -sha256 -days 3650 \
    -key "$CA_KEYS/ca.key" \
    -subj "/C=SE/O=Company/OU=Arrowhead Test Cloud/CN=$CLOUD_NAME.Company.arrowhead.eu" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$CERT_DIR/ca.crt"
fi

issue_certificate() {
  file_name=$1
  common_name=$2
  extensions=$3
  qualifier=${4:-}
  unit=${5:-Arrowhead Systems}
  subject="/C=SE/O=Company/OU=$unit/CN=$common_name"
  if [ -n "$qualifier" ]; then
    subject="$subject/dnQualifier=$qualifier"
  fi

  # Reissue a certificate whose organizational unit differs (relay certificates carry the cloud name, see below).
  if [ -f "$CERT_DIR/$file_name.crt" ] \
      && ! openssl x509 -in "$CERT_DIR/$file_name.crt" -noout -subject -nameopt RFC2253 | grep -q "OU=$unit,"; then
    rm -f "$CERT_DIR/$file_name.crt" "$CERT_DIR/$file_name.key"
  fi

  # Arrowhead 5.2.2 takes the certificate profile type (sy = system) from the subject dnQualifier;
  # reissue certificates created before the qualifier was added.
  if [ -n "$qualifier" ] && [ -f "$CERT_DIR/$file_name.crt" ] \
      && ! openssl x509 -in "$CERT_DIR/$file_name.crt" -noout -subject -nameopt RFC2253 | grep -q "dnQualifier=$qualifier"; then
    rm -f "$CERT_DIR/$file_name.crt" "$CERT_DIR/$file_name.key"
  fi

  if [ ! -f "$CERT_DIR/$file_name.key" ] || [ ! -f "$CERT_DIR/$file_name.crt" ]; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$CERT_DIR/$file_name.key"
    openssl req -new -sha256 \
      -key "$CERT_DIR/$file_name.key" \
      -subj "$subject" \
      -out "$CERT_DIR/$file_name.csr"
    openssl x509 -req -sha256 -days 825 \
      -in "$CERT_DIR/$file_name.csr" \
      -CA "$CERT_DIR/ca.crt" \
      -CAkey "$CA_KEYS/ca.key" \
      -CAcreateserial \
      -extfile "$ROOT_DIR/security/$extensions" \
      -out "$CERT_DIR/$file_name.crt"
    rm -f "$CERT_DIR/$file_name.csr"
  fi
}

issue_certificate datamanager DataManager.$CLOUD_NAME.Company.arrowhead.eu datamanager.ext sy
issue_certificate graphdbmanager GraphDBManager.$CLOUD_NAME.Company.arrowhead.eu graphdbmanager.ext sy
issue_certificate timemanager TimeManager.$CLOUD_NAME.Company.arrowhead.eu timemanager.ext sy
issue_certificate eventhandler EventHandler.$CLOUD_NAME.Company.arrowhead.eu eventhandler.ext sy
issue_certificate plantdescriptionengine PlantDescriptionEngine.$CLOUD_NAME.Company.arrowhead.eu plantdescriptionengine.ext sy
issue_certificate configuration Configuration.$CLOUD_NAME.Company.arrowhead.eu configuration.ext sy
issue_certificate choreographer Choreographer.$CLOUD_NAME.Company.arrowhead.eu choreographer.ext sy
issue_certificate serviceregistry ServiceRegistry.$CLOUD_NAME.Company.arrowhead.eu serviceregistry.ext sy
issue_certificate blacklist Blacklist.$CLOUD_NAME.Company.arrowhead.eu blacklist.ext sy
issue_certificate translation-manager TranslationManager.$CLOUD_NAME.Company.arrowhead.eu translation-manager.ext sy
issue_certificate device-qos-evaluator DeviceQoSEvaluator.$CLOUD_NAME.Company.arrowhead.eu device-qos-evaluator.ext sy
issue_certificate random-data-producer RandomDataProducer.$CLOUD_NAME.Company.arrowhead.eu random-data-producer.ext sy
issue_certificate local-cloud-manager LocalCloudManager.$CLOUD_NAME.Company.arrowhead.eu local-cloud-manager.ext sy
# Operator (sysop) certificate: Authentication binds the Sysop identity and its tokens to this certificate.
issue_certificate sysop Sysop.$CLOUD_NAME.Company.arrowhead.eu sysop.ext op
# Client-only identity without grants, used by smoke tests for negative authorization checks.
issue_certificate smoke-client SmokeClient.$CLOUD_NAME.Company.arrowhead.eu smoke-client.ext sy
issue_certificate authentication Authentication.$CLOUD_NAME.Company.arrowhead.eu authentication.ext sy
issue_certificate serviceorchestration-dynamic DynamicServiceOrchestration.$CLOUD_NAME.Company.arrowhead.eu dynamic-service-orchestration.ext sy
issue_certificate serviceorchestration-simple SimpleStoreServiceOrchestration.$CLOUD_NAME.Company.arrowhead.eu simple-store-service-orchestration.ext sy
issue_certificate consumerauthorization ConsumerAuthorization.$CLOUD_NAME.Company.arrowhead.eu consumer-authorization.ext sy
issue_certificate gatekeeper Gatekeeper.$CLOUD_NAME.Company.arrowhead.eu gatekeeper.ext sy
issue_certificate gatetunnel GateTunnel.$CLOUD_NAME.Company.arrowhead.eu gatetunnel.ext sy
issue_certificate sysmonitor SysMonitor.$CLOUD_NAME.Company.arrowhead.eu sysmonitor.ext sy
issue_certificate aigym AIGym.$CLOUD_NAME.Company.arrowhead.eu aigym.ext sy
issue_certificate certificate-authority CertificateAuthority.$CLOUD_NAME.Company.arrowhead.eu certificate-authority.ext sy
issue_certificate mqtt-broker mqtt-broker mqtt-broker.ext
issue_certificate amqp-broker amqp-broker amqp-broker.ext
issue_certificate onboarding Onboarding.$CLOUD_NAME.Company.arrowhead.eu onboarding.ext sy
# Inter-cloud relay identities of Gatekeeper and GateTunnel: own keys, client authentication only, and the cloud name as
# organizational unit. The organization CA's cross-certificate of this cloud CA permits only subjects below
# C=SE, O=Company, OU=$CLOUD_NAME (name constraint), and the relay uses the full subject as user name, so this cloud's CA
# cannot vouch for another cloud's relay identity (../Arrowhead-relay/scripts/generate-org-pki.sh).
issue_certificate gatekeeper-relay Gatekeeper.$CLOUD_NAME.Company.arrowhead.eu relay-client.ext sy "$CLOUD_NAME"
issue_certificate gatetunnel-relay GateTunnel.$CLOUD_NAME.Company.arrowhead.eu relay-client.ext sy "$CLOUD_NAME"

openssl pkcs12 -export \
  -inkey "$CERT_DIR/aigym.key" \
  -in "$CERT_DIR/aigym.crt" \
  -certfile "$CERT_DIR/ca.crt" \
  -name AIGym.$CLOUD_NAME.Company.arrowhead.eu \
  -passout "pass:$(store_password AIG)" \
  -out "$CERT_DIR/AIGym.p12"
rm -f "$CERT_DIR/aigym-truststore.p12"
keytool -importcert -noprompt \
  -alias $CLOUD_NAME.Company.arrowhead.eu \
  -file "$CERT_DIR/ca.crt" \
  -storetype PKCS12 \
  -keystore "$CERT_DIR/aigym-truststore.p12" \
  -storepass "$(store_password AIG)"

# RandomDataProducer uses PEM files and DataManager its store below runtime/; no extra copies of their keys (J7)
rm -f "$CERT_DIR/RandomDataProducer.p12" "$CERT_DIR/DataManager.p12"

AUTH_CERT_DIR="$ROOT_DIR/runtime/Authentication/config/certificate"
mkdir -p "$AUTH_CERT_DIR"
openssl pkcs12 -export \
  -inkey "$CERT_DIR/authentication.key" \
  -in "$CERT_DIR/authentication.crt" \
  -certfile "$CERT_DIR/ca.crt" \
  -name Authentication.$CLOUD_NAME.Company.arrowhead.eu \
  -passout "pass:$(store_password AUTH)" \
  -out "$AUTH_CERT_DIR/Authentication.p12"
rm -f "$AUTH_CERT_DIR/truststore.p12"
keytool -importcert -noprompt \
  -alias $CLOUD_NAME.Company.arrowhead.eu \
  -file "$CERT_DIR/ca.crt" \
  -storetype PKCS12 \
  -keystore "$AUTH_CERT_DIR/truststore.p12" \
  -storepass "$(store_password AUTH)"

chmod 600 "$CERT_DIR"/*.key "$CERT_DIR"/*.p12
chmod 644 "$CERT_DIR"/*.crt
chmod 600 "$AUTH_CERT_DIR"/*.p12

install_system_store() {
  file_name=$1
  system_name=$2
  config_name=$3
  password=$(store_password "$4")
  cert_dir="$ROOT_DIR/runtime/$config_name/config/certificate"
  mkdir -p "$cert_dir"
  openssl pkcs12 -export \
    -inkey "$CERT_DIR/$file_name.key" \
    -in "$CERT_DIR/$file_name.crt" \
    -certfile "$CERT_DIR/ca.crt" \
    -name "$system_name.$CLOUD_NAME.Company.arrowhead.eu" \
    -passout "pass:$password" \
    -out "$cert_dir/$system_name.p12"
  rm -f "$cert_dir/truststore.p12"
  keytool -importcert -noprompt \
    -alias $CLOUD_NAME.Company.arrowhead.eu \
    -file "$CERT_DIR/ca.crt" \
    -storetype PKCS12 \
    -keystore "$cert_dir/truststore.p12" \
    -storepass "$password"
  chmod 600 "$cert_dir"/*.p12
}

install_system_store serviceorchestration-dynamic DynamicServiceOrchestration DynamicServiceOrchestration DSO
install_system_store serviceorchestration-simple SimpleStoreServiceOrchestration SimpleStoreServiceOrchestration SSO
install_system_store consumerauthorization ConsumerAuthorization ConsumerAuthorization CA
install_system_store datamanager DataManager DataManager DM
install_system_store graphdbmanager GraphDBManager GraphDBManager GDM
install_system_store timemanager TimeManager TimeManager TMG
install_system_store eventhandler EventHandler EventHandler EH
install_system_store plantdescriptionengine PlantDescriptionEngine PlantDescriptionEngine PDE
install_system_store configuration Configuration Configuration CFG
install_system_store choreographer Choreographer Choreographer CHO
install_system_store serviceregistry ServiceRegistry ServiceRegistry SR
install_system_store blacklist Blacklist Blacklist BL
install_system_store translation-manager TranslationManager TranslationManager TM
install_system_store device-qos-evaluator DeviceQoSEvaluator DeviceQoSEvaluator DQE

openssl pkcs12 -export \
  -inkey "$CERT_DIR/onboarding.key" \
  -in "$CERT_DIR/onboarding.crt" \
  -certfile "$CERT_DIR/ca.crt" \
  -name Onboarding.$CLOUD_NAME.Company.arrowhead.eu \
  -passout "pass:$(store_password ONB)" \
  -out "$CERT_DIR/Onboarding.p12"
rm -f "$CERT_DIR/onboarding-truststore.p12"
keytool -importcert -noprompt \
  -alias $CLOUD_NAME.Company.arrowhead.eu \
  -file "$CERT_DIR/ca.crt" \
  -storetype PKCS12 \
  -keystore "$CERT_DIR/onboarding-truststore.p12" \
  -storepass "$(store_password ONB)"

# Certificate-only enrollment: a device enrolls with a bootstrap (manufacturer) certificate that Onboarding
# trusts and whose SHA-256 fingerprint is approved for its device name. The test manufacturer CA is separate
# from the cloud CA, so a bootstrap certificate is not accepted by any other system.
if [ ! -f "$CA_KEYS/manufacturer-ca.key" ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$CA_KEYS/manufacturer-ca.key"
  openssl req -x509 -new -sha256 -days 3650 \
    -key "$CA_KEYS/manufacturer-ca.key" \
    -subj "/C=SE/O=Test Manufacturer/CN=Test Manufacturer Device CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$CERT_DIR/manufacturer-ca.crt"
fi
if [ ! -f "$CERT_DIR/device1-bootstrap.key" ] || [ ! -f "$CERT_DIR/device1-bootstrap.crt" ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$CERT_DIR/device1-bootstrap.key"
  openssl req -new -sha256 -key "$CERT_DIR/device1-bootstrap.key" \
    -subj "/C=SE/O=Test Manufacturer/CN=Device1" -out "$CERT_DIR/device1-bootstrap.csr"
  openssl x509 -req -sha256 -days 825 -in "$CERT_DIR/device1-bootstrap.csr" \
    -CA "$CERT_DIR/manufacturer-ca.crt" -CAkey "$CA_KEYS/manufacturer-ca.key" -CAcreateserial \
    -extfile "$ROOT_DIR/security/device-bootstrap.ext" -out "$CERT_DIR/device1-bootstrap.crt"
  rm -f "$CERT_DIR/device1-bootstrap.csr"
fi
keytool -importcert -noprompt \
  -alias test-manufacturer-device-ca \
  -file "$CERT_DIR/manufacturer-ca.crt" \
  -storetype PKCS12 \
  -keystore "$CERT_DIR/onboarding-truststore.p12" \
  -storepass "$(store_password ONB)"
fingerprint=$(openssl x509 -in "$CERT_DIR/device1-bootstrap.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr 'A-F' 'a-f')
printf 'onboarding.bootstrap.certificates[%s]=Device1\n' "$fingerprint" > "$CERT_DIR/onboarding-bootstrap.properties"

if [ ! -f "$CA_KEYS/onboarding-root-ca.key" ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$CA_KEYS/onboarding-root-ca.key"
  openssl req -x509 -new -sha256 -days 3650 \
    -key "$CA_KEYS/onboarding-root-ca.key" \
    -subj "/C=SE/O=Company/OU=Arrowhead/CN=arrowhead.eu/dnQualifier=ma" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:2" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$CERT_DIR/onboarding-root-ca.crt"

  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$CA_KEYS/onboarding-organization-ca.key"
  openssl req -new -sha256 \
    -key "$CA_KEYS/onboarding-organization-ca.key" \
    -subj "/C=SE/O=Company/OU=Arrowhead/CN=Company.arrowhead.eu/dnQualifier=or" \
    -out "$CERT_DIR/onboarding-organization-ca.csr"
  openssl x509 -req -sha256 -days 2920 \
    -in "$CERT_DIR/onboarding-organization-ca.csr" \
    -CA "$CERT_DIR/onboarding-root-ca.crt" \
    -CAkey "$CA_KEYS/onboarding-root-ca.key" \
    -CAcreateserial \
    -extfile "$ROOT_DIR/security/onboarding-organization-ca.ext" \
    -out "$CERT_DIR/onboarding-organization-ca.crt"

  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$CA_KEYS/onboarding-local-cloud-ca.key"
  openssl req -new -sha256 \
    -key "$CA_KEYS/onboarding-local-cloud-ca.key" \
    -subj "/C=SE/O=Company/OU=Arrowhead/CN=$CLOUD_NAME.Company.arrowhead.eu/dnQualifier=lo" \
    -out "$CERT_DIR/onboarding-local-cloud-ca.csr"
  openssl x509 -req -sha256 -days 2190 \
    -in "$CERT_DIR/onboarding-local-cloud-ca.csr" \
    -CA "$CERT_DIR/onboarding-organization-ca.crt" \
    -CAkey "$CA_KEYS/onboarding-organization-ca.key" \
    -CAcreateserial \
    -extfile "$ROOT_DIR/security/onboarding-local-cloud-ca.ext" \
    -out "$CERT_DIR/onboarding-local-cloud-ca.crt"
  rm -f "$CERT_DIR/onboarding-organization-ca.csr" "$CERT_DIR/onboarding-local-cloud-ca.csr"
fi

cat "$CERT_DIR/onboarding-organization-ca.crt" "$CERT_DIR/onboarding-root-ca.crt" > "$CERT_DIR/onboarding-ca-chain.crt"
# no container uses a PKCS#12 copy of the onboarding CA key (J7)
rm -f "$CERT_DIR/OnboardingCA.p12"

# TLS server certificates of the MySQL servers, signed by the cloud CA. The SAN is the compose host
# name used in the JDBC URLs, so the systems connect with sslMode=verify-full. Each server mounts its
# own directory (certificate, key and CA) at /etc/mysql/tls; the files must be readable by the
# container's mysql user, which is why this directory is not restricted to the owner.
issue_database_certificate() {
  db_host=$1
  db_dir="$CERT_DIR/db/$db_host"
  mkdir -p "$db_dir"
  if [ ! -f "$db_dir/server.key" ] || [ ! -f "$db_dir/server.crt" ]; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$db_dir/server.key"
    openssl req -new -sha256 \
      -key "$db_dir/server.key" \
      -subj "/C=SE/O=Company/OU=Arrowhead Databases/CN=$db_host" \
      -out "$db_dir/server.csr"
    printf '%s\n' \
      "basicConstraints=critical,CA:FALSE" \
      "keyUsage=critical,digitalSignature,keyEncipherment" \
      "extendedKeyUsage=serverAuth" \
      "subjectAltName=DNS:$db_host,DNS:localhost" > "$db_dir/server.ext"
    openssl x509 -req -sha256 -days 825 \
      -in "$db_dir/server.csr" \
      -CA "$CERT_DIR/ca.crt" \
      -CAkey "$CA_KEYS/ca.key" \
      -CAcreateserial \
      -extfile "$db_dir/server.ext" \
      -out "$db_dir/server.crt"
    rm -f "$db_dir/server.csr" "$db_dir/server.ext"
  fi
  cp "$CERT_DIR/ca.crt" "$db_dir/ca.crt"
  chmod 755 "$CERT_DIR/db" "$db_dir"
  chmod 644 "$db_dir"/*.crt
  # private key owner-only (J13); Docker Desktop still lets the mysql user of the container read the bind mount
  chmod 600 "$db_dir/server.key"
}

for db_host in $(sed -n -E 's/^  ([a-z0-9-]+-db):$/\1/p' "$ROOT_DIR/compose.yaml" | sort -u); do
  issue_database_certificate "$db_host"
done

chmod 600 "$CERT_DIR"/*.key "$CERT_DIR"/*.p12
chmod 644 "$CERT_DIR"/*.crt
# Each container mounts only its own credential bundle (security/bundles/<service>), never this directory.
# Initial certificate revocation list (security finding H3). The CertificateAuthority rewrites security/crl/ca.crl from
# its revocation register; this empty CRL lets the brokers start before it. Re-created when missing or when it was
# signed by another key (a regenerated cloud CA).
CRL_DIR="$ROOT_DIR/security/crl"
mkdir -p "$CRL_DIR"
chmod 755 "$CRL_DIR"
if ! openssl crl -in "$CRL_DIR/ca.crl" -CAfile "$CERT_DIR/ca.crt" -noout >/dev/null 2>&1; then
  crl_work=$(mktemp -d)
  : > "$crl_work/index.txt"
  echo 01 > "$crl_work/crlnumber"
  printf '[ca]\ndefault_ca=c\n[c]\ndatabase=%s/index.txt\ncrlnumber=%s/crlnumber\ndefault_md=sha256\ndefault_crl_days=7\n' \
    "$crl_work" "$crl_work" > "$crl_work/ca.cnf"
  openssl ca -config "$crl_work/ca.cnf" -gencrl -keyfile "$CA_KEYS/ca.key" -cert "$CERT_DIR/ca.crt" \
    -out "$CRL_DIR/ca.crl" 2>/dev/null
  chmod 644 "$CRL_DIR/ca.crl"
  rm -f "$crl_work"/index.txt* "$crl_work"/crlnumber* "$crl_work/ca.cnf"
  rmdir "$crl_work"
  echo "Initial CRL written to $CRL_DIR/ca.crl"
fi

# CRL of the test manufacturer CA: Onboarding checks the bootstrap certificates against it (J4), fail closed.
"$ROOT_DIR/scripts/manufacturer-crl.sh"

"$ROOT_DIR/scripts/make-credential-bundles.sh"
echo "X.509 material is ready in $CERT_DIR"
