#!/bin/sh
# Removes AMQP broker users that are not in amqp/definitions.json (for example the CN-only user names used before the
# broker switched to full certificate subjects, security finding M1). Run by make amqp-acl after the import.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"
wanted=$(jq -r '.users[].name' amqp/definitions.json)
docker compose exec -T amqp-broker rabbitmqctl -q list_users | tail -n +2 | cut -f1 | while IFS= read -r user; do
  [ -n "$user" ] || continue
  if ! printf '%s\n' "$wanted" | grep -Fxq -- "$user"; then
    docker compose exec -T amqp-broker rabbitmqctl -q delete_user "$user" >/dev/null && echo "removed AMQP user $user"
  fi
done
