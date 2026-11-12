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

# Per-database secrets (J1): every AH_DB_ROOT_<DB> / AH_DB_PW_<DB> that compose.yaml uses must be set.
for key in $(grep -oE '\$\{AH_DB_(ROOT|PW)_[A-Z]+' compose.yaml | cut -c3- | sort -u); do
  value=$(sed -n "s/^${key}=//p" .env | tail -n 1)
  case "$value" in
    ""|replace-with-*) echo "ERROR: $key is not set in .env; run scripts/rotate-secrets.sh generate." >&2; exit 1 ;;
  esac
done

./scripts/init.sh >/dev/null
echo "Preflight checks passed."
