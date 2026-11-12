#!/bin/sh
# Builds one credential bundle per container: security/bundles/<service>/ holds only the files that container uses (its
# own key and certificate or keystore, and the trust anchors). Compose mounts the bundle at /certs; no container mounts
# security/x509, so none can read another system's key. The cloud CA key (ca.key) is only in the certificate-authority
# bundle. On Docker Desktop file modes give no protection inside a container (every bind-mounted file appears to belong
# to the container user), so the mount scope is the protection.
# Run by generate-x509.sh, and by ../Arrowhead-relay/scripts/generate-org-pki.sh after it refreshed the relay chains.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
X509="$ROOT_DIR/security/x509"
CA_KEYS="$ROOT_DIR/security/ca"  # CA signing keys (J15): an entry ca:<file> is taken from here
BUNDLES="$ROOT_DIR/security/bundles"
umask 077

# bundle <service> <file>...: a missing optional file (marked ?name) is skipped; a missing required file is an error
bundle() {
  service=$1; shift
  dir="$BUNDLES/$service"
  # empty in place: running containers keep their bind mount of this directory (2026-10-17)
  mkdir -p "$dir"; find "$dir" -mindepth 1 -delete
  for entry in "$@"; do
    file=${entry#\?}; optional=$([ "$file" != "$entry" ] && echo yes || echo no); source_dir=$X509
    case "$file" in ca:*) file=${file#ca:}; source_dir=$CA_KEYS ;; esac
    if [ -f "$source_dir/$file" ]; then
      cp "$source_dir/$file" "$dir/$file"
    elif [ "$optional" = no ]; then
      echo "make-credential-bundles: $service needs $file, which does not exist" >&2; exit 1
    fi
  done
  chmod 700 "$dir"; chmod 600 "$dir"/*
}

mkdir -p "$BUNDLES"; chmod 700 "$BUNDLES"
bundle certificate-authority  ca.crt ca:ca.key certificate-authority.crt certificate-authority.key
bundle onboarding             ca.crt Onboarding.p12 onboarding-truststore.p12
bundle sysmonitor             ca.crt sysmonitor.crt sysmonitor.key
bundle random-data-producer   ca.crt random-data-producer.crt random-data-producer.key
bundle cloud-monitor-api      ca.crt local-cloud-manager.crt local-cloud-manager.key
bundle aigym                  ca.crt aigym.crt aigym.key AIGym.p12 aigym-truststore.p12
bundle amqp-broker            ca.crt amqp-broker.crt amqp-broker.key
bundle mqtt-broker            ca.crt mqtt-broker.crt mqtt-broker.key
# Gatekeeper and GateTunnel: cloud identity, plus the separate relay identity and the organization CA (present once the
# organization PKI exists).
bundle gatekeeper             ca.crt gatekeeper.crt gatekeeper.key ?org-ca.crt ?gatekeeper-relay.key ?gatekeeper-relay-chain.crt
bundle gatetunnel             ca.crt gatetunnel.crt gatetunnel.key ?org-ca.crt ?gatetunnel-relay.key ?gatetunnel-relay-chain.crt
# The native Go and Rust core systems of the interchangeability overlays (interchangeability/compose.*.yaml) read PEM
# files; the Java core systems use their keystores in runtime/<System>/config/certificate (J15)
for core in serviceregistry authentication consumerauthorization serviceorchestration-dynamic serviceorchestration-simple; do
  bundle "$core" ca.crt "$core.crt" "$core.key"
done
echo "Credential bundles are ready in $BUNDLES"
