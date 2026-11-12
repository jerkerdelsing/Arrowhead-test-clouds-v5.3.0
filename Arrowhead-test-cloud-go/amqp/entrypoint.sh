#!/bin/sh
# Runs as the rabbitmq user on a read-only root filesystem (security finding J3): the broker reads its key and
# certificates straight from the read-only bundle /certs, and the CRL hash directory is in the tmpfs /tmp.
# Revocation (H3): the cloud CA's CRL (written by the CertificateAuthority into /crl) under the CA's subject hash.
set -eu
mkdir -p /tmp/rabbitmq-crl
ln -sf /crl/ca.crl "/tmp/rabbitmq-crl/$(openssl x509 -in /certs/ca.crt -noout -hash).r0"
exec docker-entrypoint.sh rabbitmq-server
