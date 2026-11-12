#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export AUTHENTICATION_URL=https://127.0.0.1:8444
export AUTHORIZATION_URL=https://127.0.0.1:8445
export SERVICE_REGISTRY_URL=https://127.0.0.1:8443
export CERT_DIR='security/x509'
export CRL_FILE='security/crl/ca.crl'
export SECRETS_ENV_FILE='.env'
export COMPOSE_PROJECT_NAME='arrowhead-v53-test-cloud'
python3 scripts/configure-console-edit-policies.py
