#!/bin/sh
set -eu
mkdir -p /tmp/rabbitmq-crl
ln -sf /run/trust/current.crl.pem "/tmp/rabbitmq-crl/$(openssl x509 -in /run/ca.pem -noout -hash).r0"
exec docker-entrypoint.sh rabbitmq-server
