#!/bin/sh
# SPDX-License-Identifier: EPL-2.0
# Rust test cloud v5.3.0 (2026-11-12): start compose.json (v530/generate.py) in bootstrap order, then the local policies.
#   deploy.sh up      start and configure (idempotent; safe to re-run)
#   deploy.sh down    stop and remove the containers; secrets, state and certificates are kept
# Requires v530/build.sh and v530/generate.py first (see v530/README.md).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
C="docker compose -f compose.json"
step() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; "$@"; }
case ${1:-up} in
  down) $C down; exit 0 ;;
  up) ;;
  *) echo "usage: deploy.sh up|down" >&2; exit 2 ;;
esac
step $C config --quiet
step $C up -d --wait --wait-timeout 180 amqp-broker mqtt-broker certificateauthority
step $C up -d --wait --wait-timeout 180 serviceregistry authentication consumer-authorization edge
step $C up -d --wait --wait-timeout 180 serviceorchestration-simple serviceorchestration-dynamic blacklist
step python3 v530/configure.py
step $C up -d --wait --wait-timeout 300
step $C ps --format 'table {{.Service}}\t{{.Status}}'
