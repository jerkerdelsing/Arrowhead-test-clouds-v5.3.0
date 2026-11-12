#!/bin/sh
# Idempotent schema upgrade for an existing Java DSO database; no existing orchestration data is removed.
set -eu
cd "$(dirname "$0")/.."
docker compose exec -T serviceorchestration-dynamic-db sh -c '
  config=$(mktemp)
  trap '\''rm -f "$config"'\'' EXIT HUP INT TERM
  { printf "[client]\nuser=root\npassword="; cat "$MYSQL_ROOT_PASSWORD_FILE"; printf "\nprotocol=socket\n"; } > "$config"
  mysql --defaults-extra-file="$config" ah_serviceorchestration_dynamic
' < db/zy-dso-plant-rules.sql
echo "DSO plant-rule schema is current"
