#!/bin/sh
# Per-cloud secrets (security finding H2): random values in .env (mode 600), applied to the running cloud.
#
#   rotate-secrets.sh generate   add every missing secret to .env (random); existing values are kept
#   rotate-secrets.sh rotate     new random values for all secrets; the old .env is kept as .env.previous (600)
#   rotate-secrets.sh files      (re)write secrets/<KEY> from .env; generate and rotate do this too
#   rotate-secrets.sh forget-previous   delete .env.previous once a rotation is verified (J7)
#   rotate-secrets.sh apply      bring the running cloud to the .env values (see below); safe to re-run
#   rotate-secrets.sh apply-database   only step 2 below (database users)
#   rotate-secrets.sh restart    recreate the cloud in bootstrap order so every container reads the new values
#   rotate-secrets.sh all        generate + apply + restart (first use on a cloud that still has the defaults)
#
# apply changes, in order:
#   1. Authentication identities (systems, SmokeClient, Sysop): identity/change with the system's own certificate,
#      never a login (a login would replace the running system's token). Tried first with the new value (already done),
#      then with the previous value, then with the former fixed default.
#   2. Database users, per database (J1): root gets its own AH_DB_ROOT_<DB>; the system's own user gets
#      AH_DB_PW_<DB> (support systems: created if missing, SELECT/INSERT/UPDATE/DELETE on their schema only);
#      the former shared user ah-operator is dropped. Old root passwords tried: new, .env.previous, the former
#      shared DB_ROOT_PSW, the container's MYSQL_ROOT_PASSWORD.
#   3. Keystores: generate-x509.sh rebuilds every PKCS#12 store with its system's AH_STORE_PW_<ABBR>, then the bundles.
# Secret keys and the console password need no live change; they take effect with restart.
#
# Containers get secrets only as files (security finding J7): secrets/<KEY> (directory 700, files 600) is written from
# .env and mounted by Compose under /run/secrets of the containers that need it; no secret is in a container
# environment. The console password is not kept in .env: only its hash is, and the password itself goes to the macOS
# keychain (service arrowhead-console-<project>), or is printed once where there is no keychain.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"
ENV_FILE="$ROOT_DIR/.env"
PREVIOUS_FILE="$ROOT_DIR/.env.previous"
CERT_DIR=${CERT_DIR:-security/x509}
umask 077

# Identity secrets: KEY|system name|certificate file stem|former fixed default(s)
IDENTITIES="AH_PW_SR|ServiceRegistry|serviceregistry|SR-test-52 123456
AH_PW_AUTH|Authentication|authentication|
AH_PW_DSO|DynamicServiceOrchestration|serviceorchestration-dynamic|DSO-test-52
AH_PW_SSO|SimpleStoreServiceOrchestration|serviceorchestration-simple|SSO-test-52
AH_PW_CA|ConsumerAuthorization|consumerauthorization|CA-test-52
AH_PW_BL|Blacklist|blacklist|BL-test-52
AH_PW_TM|TranslationManager|translation-manager|TM-test-52
AH_PW_DQE|DeviceQoSEvaluator|device-qos-evaluator|DQE-test-52
AH_PW_DM|DataManager|datamanager|DM-test-52
AH_PW_GDM|GraphDBManager|graphdbmanager|
AH_PW_TMG|TimeManager|timemanager|TMG-test-52
AH_PW_CFG|Configuration|configuration|CFG-test-52
AH_PW_CHO|Choreographer|choreographer|CHO-test-52
AH_PW_RDP|RandomDataProducer|random-data-producer|RDP-test-52
AH_PW_SM|SysMonitor|sysmonitor|SM-test-52
AH_PW_EH|EventHandler|eventhandler|EH-test-52
AH_PW_ONB|Onboarding|onboarding|ONB-test-52
AH_PW_CAU|CertificateAuthority|certificate-authority|CAU-test-52
AH_PW_LCM|LocalCloudManager|local-cloud-manager|LCM-test-52
AH_PW_GK|Gatekeeper|gatekeeper|GK-test-52
AH_PW_GT|GateTunnel|gatetunnel|GT-test-52
AH_PW_AIG|AIGym|aigym|AIG-test-52
AH_PW_PDE|PlantDescriptionEngine|plantdescriptionengine|PDE-test-52
AH_PW_SMK|SmokeClient|smoke-client|SMK-test-52
ARROWHEAD_SYSOP_PASSWORD|Sysop|sysop|xFNHbh2mQyIp1gmimeTC"

# Every database and its system's own user: KEY|database service|user|runtime config directory|schema
# (schema set: support system whose user this script provisions with data access only; empty: upstream core image)
DB_USERS="AH_DB_PW_SERVICEREGISTRY|serviceregistry-db|serviceregistry|ServiceRegistry
AH_DB_PW_DYNAMICSERVICEORCHESTRATION|serviceorchestration-dynamic-db|serviceorchestration-dynamic|DynamicServiceOrchestration
AH_DB_PW_SIMPLESTORESERVICEORCHESTRATION|serviceorchestration-simple-db|serviceorchestration-simple|SimpleStoreServiceOrchestration
AH_DB_PW_CONSUMERAUTHORIZATION|consumerauthorization-db|consumerauthorization|ConsumerAuthorization
AH_DB_PW_AUTHENTICATION|authentication-db|authentication|Authentication
AH_DB_PW_BLACKLIST|blacklist-db|blacklist|Blacklist
AH_DB_PW_TRANSLATIONMANAGER|translation-manager-db|translationmanager|TranslationManager
AH_DB_PW_DEVICEQOSEVALUATOR|device-qos-evaluator-db|deviceqosevaluator|DeviceQoSEvaluator
AH_DB_PW_ONBOARDING|onboarding-db|onboarding||ah_onboarding
AH_DB_PW_DATAMANAGER|datamanager-db|datamanager|DataManager|ah_datamanager
AH_DB_PW_TIMEMANAGER|timemanager-db|timemanager|TimeManager|ah_timemanager
AH_DB_PW_EVENTHANDLER|eventhandler-db|eventhandler|EventHandler|ah_eventhandler
AH_DB_PW_PLANTDESCRIPTIONENGINE|plantdescriptionengine-db|plantdescriptionengine|PlantDescriptionEngine|ah_plantdescriptionengine
AH_DB_PW_CONFIGURATION|configuration-db|configuration|Configuration|ah_configuration
AH_DB_PW_CHOREOGRAPHER|choreographer-db|choreographer|Choreographer|ah_choreographer"

# Keystore and truststore password of each system with PKCS#12 stores (J7: no shared store password)
STORE_KEYS="AH_STORE_PW_SR AH_STORE_PW_DSO AH_STORE_PW_SSO AH_STORE_PW_CA AH_STORE_PW_AUTH AH_STORE_PW_BL AH_STORE_PW_TM
AH_STORE_PW_DQE AH_STORE_PW_DM AH_STORE_PW_GDM AH_STORE_PW_TMG AH_STORE_PW_EH AH_STORE_PW_PDE AH_STORE_PW_CFG AH_STORE_PW_CHO AH_STORE_PW_ONB
AH_STORE_PW_AIG"

# GraphDBManager's GraphDB (not MySQL): its admin password and the system's own GraphDB user password
OTHER_KEYS="AH_AUTHENTICATION_SECRET_KEY CONSOLE_PROXY_SECRET AH_GRAPHDB_ADMIN_GRAPHDBMANAGER AH_GRAPHDB_PW_GRAPHDBMANAGER"
SECRETS_DIR="$ROOT_DIR/secrets"
# keys that were in .env before J7 and are removed from it: the shared store password, the plaintext console password
RETIRED_KEYS="X509_STORE_PASSWORD CONSOLE_PASSWORD"

random_value() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"; }
env_get() { [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | tail -n 1 || true; }
env_unset() {
  grep -q "^$1=" "$ENV_FILE" || return 0
  tmp=$(mktemp "$ROOT_DIR/.env.XXXXXX")
  grep -v "^$1=" "$ENV_FILE" > "$tmp" || true
  mv "$tmp" "$ENV_FILE"; chmod 600 "$ENV_FILE"
}
env_set() {
  if grep -q "^$1=" "$ENV_FILE"; then
    tmp=$(mktemp "$ROOT_DIR/.env.XXXXXX")
    awk -v k="$1" -v v="$2" 'BEGIN { FS = OFS = "=" } $1 == k { print k "=" v; next } { print }' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
}
has_java_registry() { grep -q '^  serviceregistry-db:' compose.yaml; }
db_users() {
  if has_java_registry; then printf '%s\n' "$DB_USERS"
  else printf '%s\n' "$DB_USERS" | grep -v '^AH_DB_PW_SERVICEREGISTRY|'; fi
}

all_keys() {
  printf '%s\n' "$IDENTITIES" | cut -d'|' -f1
  db_users | cut -d'|' -f1
  db_users | cut -d'|' -f1 | sed 's/^AH_DB_PW_/AH_DB_ROOT_/'
  for key in $STORE_KEYS $OTHER_KEYS AH_CONSUMER_AUTHORIZATION_CRYPTO_KEY; do echo "$key"; done
}

console_hash() {
  python3 -c 'import base64, hashlib, os, sys
salt = os.urandom(16)
key = hashlib.scrypt(sys.argv[1].encode(), salt=salt, n=16384, r=8, p=1, dklen=32)
print("scrypt:" + base64.b64encode(salt).decode() + ":" + base64.b64encode(key).decode())' "$1"
}

generate() {  # $1 = force (rotate) or empty
  [ -f "$ENV_FILE" ] || { echo "No .env; run make init first" >&2; exit 1; }
  if [ "${1:-}" = force ]; then cp -p "$ENV_FILE" "$PREVIOUS_FILE"; chmod 600 "$PREVIOUS_FILE"; fi
  created=0
  for key in $(all_keys); do
    current=$(env_get "$ENV_FILE" "$key")
    if [ "${1:-}" = force ] || [ -z "$current" ] || [ "${current#replace-with-}" != "$current" ]; then
      length=32; [ "$key" = AH_CONSUMER_AUTHORIZATION_CRYPTO_KEY ] && length=16
      env_set "$key" "$(random_value "$length")"; created=$((created + 1))
    fi
  done
  console_password "${1:-}"
  for key in $RETIRED_KEYS; do env_unset "$key"; done
  write_files
  echo "Secrets in .env: $created new value(s)$([ "${1:-}" = force ] && echo "; previous values in .env.previous")"
}

# The console container gets only a salted scrypt hash of its password; the password is kept outside .env (J7).
# A plaintext CONSOLE_PASSWORD still in .env (before J7) is moved to the keychain.
console_service() { echo "arrowhead-console-$(env_get "$ENV_FILE" COMPOSE_PROJECT_NAME)"; }
console_password() {  # $1 = force or empty
  password=$(env_get "$ENV_FILE" CONSOLE_PASSWORD)
  if [ "${1:-}" = force ] || { [ -z "$password" ] && [ -z "$(env_get "$ENV_FILE" CONSOLE_PASSWORD_HASH)" ]; }; then
    password=$(random_value 32)
  fi
  [ -n "$password" ] || return 0
  env_set CONSOLE_PASSWORD_HASH "$(console_hash "$password")"
  if command -v security >/dev/null 2>&1; then
    security add-generic-password -U -a "$(env_get "$ENV_FILE" COMPOSE_PROJECT_NAME)" -s "$(console_service)" \
      -l "Arrowhead console $(env_get "$ENV_FILE" COMPOSE_PROJECT_NAME)" -w "$password"
    echo "Console password: in the keychain (service $(console_service)); make console-password prints it"
  else
    echo "Console password (shown once, not stored): $password"
  fi
}

# secrets/<KEY>: one file per Compose secret of compose.yaml and of the native-core overlays (J7, J19), nothing else
# (operator-only secrets such as the Sysop password stay in .env; interchangeability/bootstrap-authentication.sh writes
# them to secrets/bootstrap only while a native Authentication seeds its identities). Rewritten whole; no trailing newline.
COMPOSE_SECRET_FILES="compose.yaml interchangeability/compose.go.yaml interchangeability/compose.rust.yaml"
write_files() {
  mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
  find "$SECRETS_DIR" -mindepth 1 -maxdepth 1 -type f -delete
  # shellcheck disable=SC2086
  for key in $(cat $COMPOSE_SECRET_FILES 2>/dev/null | sed -n 's#^  \([A-Z0-9_]*\): { file: \./secrets/\1 }$#\1#p' | sort -u); do
    value=$(env_get "$ENV_FILE" "$key")
    [ -n "$value" ] || { echo "  $key missing in .env; run generate" >&2; exit 1; }
    printf '%s' "$value" > "$SECRETS_DIR/$key"
  done
  chmod 600 "$SECRETS_DIR"/*
  echo "Secret files: $(ls "$SECRETS_DIR" | wc -l | tr -d ' ') in secrets/"
}

auth_url() { echo "https://127.0.0.1:$(env_get "$ENV_FILE" AUTHENTICATION_PORT)"; }
change_identity() {  # system stem old new -> HTTP code
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 --cacert "$CERT_DIR/ca.crt" \
    --cert "$CERT_DIR/$2.crt" --key "$CERT_DIR/$2.key" -H 'Content-Type: application/json' \
    --data "{\"systemName\":\"$1\",\"credentials\":{\"password\":\"$3\"},\"newCredentials\":{\"password\":\"$4\"}}" \
    "$(auth_url)/authentication/identity/change"
}

apply_identities() {
  printf '%s\n' "$IDENTITIES" | while IFS='|' read -r key system stem defaults; do
    new=$(env_get "$ENV_FILE" "$key")
    [ -n "$new" ] || { echo "  $system: $key missing in .env" >&2; exit 1; }
    [ -f "$CERT_DIR/$stem.crt" ] || { echo "  $system: no certificate, skipped"; continue; }
    result="not provisioned (created later with the new password)"
    for old in "$new" "$(env_get "$PREVIOUS_FILE" "$key")" $defaults; do
      [ -n "$old" ] || continue
      code=$(change_identity "$system" "$stem" "$old" "$new")
      if [ "$code" = 200 ]; then
        [ "$old" = "$new" ] && result="already current" || result="changed"
        break
      fi
    done
    echo "  identity $system: $result"
  done
}

db_exec() {  # service password sql
  docker compose exec -T -e MYSQL_PWD="$2" "$1" mysql -uroot -N -e "$3" 2>/dev/null
}
apply_database() {
  for service in $(docker compose config --services | grep -- '-db$'); do
    [ -n "$(docker compose ps -q "$service")" ] || { echo "  $service: not running, skipped"; continue; }
    users=$(db_users | awk -F'|' -v s="$service" '$2 == s')
    [ -n "$users" ] || { echo "  $service: not in DB_USERS" >&2; exit 1; }
    key=$(echo "$users" | cut -d'|' -f1); user=$(echo "$users" | cut -d'|' -f3); schema=$(echo "$users" | cut -d'|' -f5)
    root_key=$(echo "$key" | sed 's/^AH_DB_PW_/AH_DB_ROOT_/')
    root_new=$(env_get "$ENV_FILE" "$root_key"); own=$(env_get "$ENV_FILE" "$key")
    [ -n "$root_new" ] && [ -n "$own" ] || { echo "  $service: $root_key or $key missing; run generate" >&2; exit 1; }
    running=$(docker compose exec -T "$service" sh -c 'cat /run/secrets/db-root-password 2>/dev/null || printenv MYSQL_ROOT_PASSWORD' 2>/dev/null || true)
    root_old=""
    for candidate in "$root_new" "$(env_get "$PREVIOUS_FILE" "$root_key")" "$(env_get "$ENV_FILE" DB_ROOT_PSW)" \
        "$(env_get "$PREVIOUS_FILE" DB_ROOT_PSW)" "$running"; do
      [ -n "$candidate" ] && db_exec "$service" "$candidate" 'SELECT 1' >/dev/null && { root_old=$candidate; break; }
    done
    [ -n "$root_old" ] || { echo "  $service: no known root password works" >&2; exit 1; }
    statements=""
    if [ -n "$schema" ]; then
      # support system: its own user, data access on its schema only, no localhost twin (J1)
      statements="CREATE USER IF NOT EXISTS '$user'@'%' IDENTIFIED BY '$own';"
      for host in $(db_exec "$service" "$root_old" "SELECT host FROM mysql.user WHERE user='$user' AND host<>'%'"); do
        statements="$statements DROP USER '$user'@'$host';"
      done
      statements="$statements ALTER USER '$user'@'%' IDENTIFIED BY '$own';
        REVOKE ALL PRIVILEGES, GRANT OPTION FROM '$user'@'%';
        GRANT SELECT, INSERT, UPDATE, DELETE ON \`$schema\`.* TO '$user'@'%';"
    else
      for host in $(db_exec "$service" "$root_old" "SELECT host FROM mysql.user WHERE user='$user'"); do
        statements="$statements ALTER USER '$user'@'$host' IDENTIFIED BY '$own';"
      done
    fi
    # the former shared user of every database (J1)
    for host in $(db_exec "$service" "$root_old" "SELECT host FROM mysql.user WHERE user='ah-operator'"); do
      statements="$statements DROP USER 'ah-operator'@'$host';"
    done
    for host in $(db_exec "$service" "$root_old" "SELECT host FROM mysql.user WHERE user='root'"); do
      statements="$statements ALTER USER 'root'@'$host' IDENTIFIED BY '$root_new';"
    done
    db_exec "$service" "$root_old" "$statements FLUSH PRIVILEGES;" >/dev/null \
      || { echo "  $service: user changes failed" >&2; exit 1; }
    echo "  database $service: own root, $user${schema:+ (data access on $schema)}, no ah-operator"
  done
}

apply() {
  echo "Authentication identities:"; apply_identities
  echo "Database users:"; apply_database
  echo "Keystores:"; ./scripts/generate-x509.sh >/dev/null && echo "  rebuilt, each with its system's AH_STORE_PW_<ABBR>"
}

restart() {
  # Bootstrap order: ServiceRegistry, Authentication, then the rest; every service whose environment changed is
  # recreated (all of them after a rotation).
  docker compose up -d --no-build --pull never --wait serviceregistry
  docker compose up -d --no-build --pull never --wait authentication-db authentication
  # A slow Java system can still be starting when its dependents are due; retry until all are up.
  for attempt in 1 2 3 4; do
    docker compose up -d --no-build --pull never && return 0
    echo "Some dependencies were not healthy yet (attempt $attempt); retrying in 30 s" >&2
    sleep 30
  done
  return 1
}

case "${1:-}" in
  generate) generate ;;
  rotate) generate force ;;
  files) write_files ;;
  forget-previous) rm -f "$PREVIOUS_FILE"; echo "Removed .env.previous" ;;
  apply) apply ;;
  apply-database) echo "Database users:"; apply_database ;;
  restart) restart ;;
  all) generate; apply; restart ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
