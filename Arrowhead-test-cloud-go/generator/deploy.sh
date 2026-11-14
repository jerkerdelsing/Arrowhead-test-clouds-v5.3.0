#!/bin/sh
# SPDX-License-Identifier: EPL-2.0
# Go test cloud v5.3.0 (2026-11-11): bootstrap of compose.yaml (generator/generate.py) in the order of the 5.2 GoCloud's
# `make up-go`, without its build steps (images from generator/build.sh) and without configure-intercloud.sh (no federation).
#   deploy.sh up      start, identities and policies (idempotent; safe to re-run)
#   deploy.sh down    stop and remove the containers; volumes, secrets and certificates are kept
# Requires scripts/init.sh, scripts/generate-x509.sh and scripts/make-go-runtime.sh first (see generator/README.md).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
C="docker compose"
step() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; "$@"; }
case ${1:-up} in
  down) $C down; exit 0 ;;
  up) ;;
  *) echo "usage: deploy.sh up|down" >&2; exit 2 ;;
esac
step ./scripts/preflight.sh
step $C config --quiet
step $C up -d --wait amqp-broker mqtt-broker
# Empty registry snapshot (new volume): bootstrap with generator/bootstrap-serviceregistry.yaml until Authentication's identity
# service is registered, then the registry as configured. The snapshot is read from the volume, not through the API.
SR_VOLUME=$($C config --format json | jq -r '.volumes["serviceregistry-data"].name')
sr_has_identity() {
  docker run --rm -v "$SR_VOLUME":/d:ro --entrypoint sh alpine:3.22 -c \
    'grep -q "\"Authentication\"" /d/serviceregistry.json 2>/dev/null && grep -q "\"identity\"" /d/serviceregistry.json'
}
if ! docker volume inspect "$SR_VOLUME" >/dev/null 2>&1 || ! sr_has_identity; then
  step $C -f compose.yaml -f generator/bootstrap-serviceregistry.yaml up -d --wait serviceregistry authentication
  attempt=0
  until sr_has_identity; do
    attempt=$((attempt + 1)); [ $attempt -le 40 ] || { echo "Authentication did not register within 2 minutes" >&2; exit 1; }
    sleep 3
  done
  echo "ServiceRegistry bootstrap: Authentication identity service registered"
fi
step $C up -d --wait serviceregistry authentication
# Authentication creates Sysop (bootstrap password file) on an empty identity store; then the other identities.
step ./scripts/provision-authentication-identities.sh
step ./scripts/configure-authentication-mtls-registry.sh
step ./scripts/register-authentication-services.sh
step ./scripts/register-amqp-interface-templates.sh
for s in gatekeeper gatetunnel sysmonitor timemanager plantdescriptionengine configuration choreographer aigym smoke-client; do
  step ./scripts/provision-$s-identity.sh
done
step $C up -d --wait consumerauthorization datamanager
step ./scripts/configure-orchestration-security-policies.sh
step ./scripts/configure-random-producer-policy.sh
# Blacklist check (J12) before the systems with a Blacklist filter serve other systems
step ./scripts/configure-blacklist-policy.sh
step $C up -d --wait
for p in gatekeeper-policy gatetunnel-policy sysmonitor-policy all-sysmonitor-policies timemanager-policy eventhandler-policy \
         plantdescriptionengine-policy pde-dso-policy configuration-policy choreographer-policy onboarding-policy aigym-policy \
         translation-policy datamanager-monitoring-policy; do
  step ./scripts/configure-$p.sh
done
step $C ps --format 'table {{.Service}}\t{{.Status}}'
