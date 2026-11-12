#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

command -v docker >/dev/null 2>&1 || {
  echo "ERROR: Docker is not installed or is not on PATH." >&2
  exit 1
}

docker compose version >/dev/null 2>&1 || {
  echo "ERROR: Docker Compose v2 is required." >&2
  exit 1
}

[ -f .env ] || {
  echo "ERROR: .env is missing. Run 'make init' first." >&2
  exit 1
}

if grep -Eq '^DB_(ROOT|AH_OPERATOR)_PSW=replace-with-' .env; then
  echo "ERROR: Replace the example database passwords in .env." >&2
  exit 1
fi

for key in DB_ROOT_PSW DB_AH_OPERATOR_PSW; do
  value=$(sed -n "s/^${key}=//p" .env | tail -n 1)
  [ -n "$value" ] || {
    echo "ERROR: $key must not be empty in .env." >&2
    exit 1
  }
done

./scripts/init.sh >/dev/null
echo "Preflight checks passed."
