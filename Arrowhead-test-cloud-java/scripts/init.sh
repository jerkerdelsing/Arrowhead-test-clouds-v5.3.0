#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env."
else
  echo ".env already exists; left unchanged."
fi

for system in \
  ServiceRegistry \
  DynamicServiceOrchestration \
  SimpleStoreServiceOrchestration \
  ConsumerAuthorization \
  Authentication \
  Blacklist \
  TranslationManager \
  DeviceQoSEvaluator
do
  mkdir -p "runtime/$system/config"
done

echo "Runtime configuration directories are ready."

# Random per-cloud secrets (H2): system and operator passwords, database users, keystores, secret keys, console login
./scripts/rotate-secrets.sh generate
