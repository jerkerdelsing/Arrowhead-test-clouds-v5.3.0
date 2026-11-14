#!/bin/sh
# SPDX-License-Identifier: EPL-2.0
# Java test cloud v5.3.0 (Compose project arrowhead-v53-test-cloud) from images built from Eclipse-Arrowhead-java.
#   deploy.sh up     install generator/compose.json as compose.yaml and bring the cloud up in bootstrap order
#   deploy.sh down   stop and remove the containers; volumes (the cloud's state) are kept
# Prerequisites, in this order: scripts/init.sh, scripts/generate-x509.sh, the relay files of generator/README.md,
# python3 generator/prepare.py, python3 generator/build.py. No inter-cloud federation: configure-intercloud.sh is not run.
set -eu
cd "$(dirname -- "$0")/.."
PROJECT=arrowhead-v53-test-cloud
STEP=${1:?usage: deploy.sh up|down}
C="docker compose -p $PROJECT -f compose.yaml"

case "$STEP" in
up)
  python3 generator/generate.py
  cp generator/compose.json compose.yaml; chmod 600 compose.yaml
  grep -q '^user LocalCloudConfigurator\.' amqp/acl || printf '\nuser LocalCloudConfigurator.TestCloud.Company.arrowhead.eu\npublish TestCloud.sysmonitor.LocalCloudConfigurator.LocalCloudConfigurator.#\n' >> amqp/acl
  grep -q '^user SoLocalCloudConfigurator\.' amqp/acl || printf '\nuser SoLocalCloudConfigurator.TestCloud.Company.arrowhead.eu\npublish TestCloud.sysmonitor.SoLocalCloudConfigurator.SoLocalCloudConfigurator.#\n' >> amqp/acl
  python3 scripts/generate-amqp-definitions.py
  $C up -d --no-build --pull never --wait serviceregistry authentication-db authentication
  ./scripts/provision-authentication-identities.sh
  ./generator/provision-extra-identities.sh
  ./scripts/configure-authentication-mtls-registry.sh
  $C restart authentication
  ./scripts/register-authentication-services.sh
  ./scripts/register-amqp-interface-templates.sh
  for s in gatekeeper gatetunnel sysmonitor timemanager plantdescriptionengine configuration choreographer aigym smoke-client; do
    ./scripts/provision-$s-identity.sh
  done
  $C up -d --no-build --pull never --wait amqp-broker mqtt-broker consumerauthorization datamanager
  ./scripts/configure-orchestration-security-policies.sh
  ./scripts/configure-orchestration-dependency-policies.sh
  ./scripts/configure-random-producer-policy.sh
  $C up -d --no-build --pull never --wait serviceorchestration-dynamic-db
  ./scripts/migrate-dso-plant-rules-db.sh
  $C up -d --no-build --pull never --wait --wait-timeout 600 $($C config --services | grep -v '^random-data-producer$')
  for s in gatekeeper gatetunnel sysmonitor; do ./scripts/configure-$s-policy.sh; done
  ./scripts/configure-all-sysmonitor-policies.sh
  for s in timemanager deviceqosevaluator eventhandler plantdescriptionengine configuration choreographer; do ./scripts/configure-$s-policy.sh; done
  ./scripts/migrate-onboarding-db.sh
  for s in onboarding aigym datamanager-monitoring; do ./scripts/configure-$s-policy.sh; done
  ./scripts/configure-graphdbmanager-policies.sh
  ./scripts/configure-localcloudconfigurator-policy.sh
  ./scripts/configure-solocalcloudconfigurator-policy.sh
  $C up -d --no-build --pull never random-data-producer
  $C ps --format 'table {{.Service}}\t{{.Status}}' ;;
down)
  $C down --remove-orphans ;;
*) echo "usage: deploy.sh up|down" >&2; exit 2 ;;
esac
