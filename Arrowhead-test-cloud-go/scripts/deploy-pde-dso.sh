#!/bin/sh
# Requires a running initialized Go cloud. Existing state volumes are preserved.
set -eu
cd "$(dirname "$0")/.."
./scripts/build-go-native.sh
./scripts/make-go-runtime.sh
./scripts/configure-pde-dso-policy.sh
docker compose build serviceregistry serviceorchestration-dynamic plantdescriptionengine cloud-monitor-api cloud-monitor-ui
docker compose stop plantdescriptionengine
docker compose up -d --no-deps --wait --wait-timeout 180 serviceregistry serviceorchestration-dynamic serviceorchestration-simple
docker compose up -d --no-deps --wait --wait-timeout 180 plantdescriptionengine cloud-monitor-api cloud-monitor-ui
