#!/bin/sh
set -eu
. "$(dirname -- "$0")/lib-secrets.sh"
_require_secret=$(secret ARROWHEAD_SYSOP_PASSWORD)
_require_secret=$(secret AH_PW_SMK)

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

[ -f .env ] || {
  echo "ERROR: .env is missing. Run 'make init' first." >&2
  exit 1
}

env_value() {
  key=$1
  fallback=$2
  value=$(sed -n "s/^${key}=//p" .env | tail -n 1)
  printf '%s' "${value:-$fallback}"
}

bind=$(env_value BIND_ADDRESS 127.0.0.1)
case "$bind" in
  0.0.0.0|::) bind=127.0.0.1 ;;
esac

failed=0
check() {
  name=$1
  port=$2
  path=$3
  response_file="${TMPDIR:-/tmp}/arrowhead-smoke-response.$$"
  http_code=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' --max-time 5 "http://${bind}:${port}${path}" || true)
  if [ "$http_code" = 200 ]; then
    printf '%-36s %s\n' "$name" OK
  elif [ "$http_code" = 401 ] && grep -q '"exceptionType":"AUTH"' "$response_file"; then
    printf '%-36s %s\n' "$name" 'OK (authentication enforced)'
  else
    printf '%-36s HTTP %s %s\n' "$name" "${http_code:-000}" FAILED
    failed=1
  fi
  rm -f "$response_file"
}

check_mtls() {
  name=$1
  port=$2
  path=$3
  response_file="${TMPDIR:-/tmp}/arrowhead-smoke-response.$$"
  http_code=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' --max-time 5 \
    --cacert security/x509/ca.crt \
    --cert security/x509/local-cloud-manager.crt \
    --key security/x509/local-cloud-manager.key \
    "https://${bind}:${port}${path}" || true)
  if [ "$http_code" = 200 ]; then
    printf '%-36s %s\n' "$name" 'OK (mTLS)'
  else
    printf '%-36s HTTP %s %s\n' "$name" "${http_code:-000}" FAILED
    failed=1
  fi
  rm -f "$response_file"
}

check_https() {
  name=$1
  port=$2
  path=$3
  response_file="${TMPDIR:-/tmp}/arrowhead-smoke-response.$$"
  http_code=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' --max-time 5 \
    --cacert security/x509/ca.crt \
    "https://${bind}:${port}${path}" || true)
  if [ "$http_code" = 200 ]; then
    printf '%-36s %s\n' "$name" 'OK (HTTPS)'
  else
    printf '%-36s HTTP %s %s\n' "$name" "${http_code:-000}" FAILED
    failed=1
  fi
  rm -f "$response_file"
}

# check_mtls_authenticated <name> <port> <path> [identity]: identity sysop (default; management endpoints) or smoke
# (the test identity SmokeClient, for ordinary services). Never a running system's identity (J6): a login replaces
# the token that system uses for its own calls.
check_mtls_authenticated() {
  name=$1
  port=$2
  path=$3
  case "${4:-sysop}" in
    smoke) system=SmokeClient stem=smoke-client password=$(secret AH_PW_SMK) ;;
    *) system=Sysop stem=sysop password=$(secret ARROWHEAD_SYSOP_PASSWORD) ;;
  esac
  response_file="${TMPDIR:-/tmp}/arrowhead-smoke-response.$$"
  token=$(curl --silent --show-error --fail --max-time 5 \
    --cacert security/x509/ca.crt \
    --cert "security/x509/$stem.crt" \
    --key "security/x509/$stem.key" \
    -H 'Content-Type: application/json' \
    --data "{\"systemName\":\"$system\",\"credentials\":{\"password\":\"$password\"}}" \
    "https://${bind}:$(env_value AUTHENTICATION_PORT 8444)/authentication/identity/login" | jq -er '.token' || true)
  http_code=$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' --max-time 5 \
    --cacert security/x509/ca.crt \
    --cert "security/x509/$stem.crt" \
    --key "security/x509/$stem.key" \
    -H "Authorization: Bearer IDENTITY-TOKEN//$token" \
    "https://${bind}:${port}${path}" || true)
  if [ "$http_code" = 200 ]; then
    printf '%-36s %s\n' "$name" 'OK (mTLS + identity token)'
  else
    printf '%-36s HTTP %s %s\n' "$name" "${http_code:-000}" FAILED
    failed=1
  fi
  rm -f "$response_file"
}

check_mtls_authenticated ServiceRegistry "$(env_value SERVICEREGISTRY_PORT 8443)" /serviceregistry/monitor/echo

if [ "${SMOKE_ONBOARDING_ONLY:-0}" != 1 ]; then
  check_mtls_authenticated DynamicServiceOrchestration "$(env_value DYNAMIC_ORCHESTRATION_PORT 8441)" "/serviceorchestration/general/mgmt/get-config?keys=server.port"
  check_mtls_authenticated ConsumerAuthorization "$(env_value CONSUMER_AUTHORIZATION_PORT 8445)" /consumerauthorization/monitor/echo
fi

if docker compose ps --services --status running | grep -qx datamanager; then
  check_mtls_authenticated DataManager "$(env_value DATAMANAGER_PORT 8461)" /datamanager/data-historian/systems smoke
fi

if docker compose ps --services --status running | grep -qx graphdbmanager; then
  check_mtls_authenticated GraphDBManager "$(env_value GRAPHDBMANAGER_PORT 8467)" /graphdbmanager/data-historian/systems smoke
fi

if docker compose ps --services --status running | grep -qx plantdescriptionengine; then
  check_mtls_authenticated PlantDescriptionEngine "$(env_value PLANTDESCRIPTIONENGINE_PORT 8432)" /plantdescriptionengine/monitor/alarms smoke
fi
if docker compose ps --services --status running | grep -qx timemanager; then
  check_mtls_authenticated TimeManager "$(env_value TIMEMANAGER_PORT 8463)" /timemanager/time smoke
fi

if docker compose ps --services --status running | grep -qx eventhandler; then
  check_mtls_authenticated EventHandler "$(env_value EVENTHANDLER_PORT 8455)" "/eventhandler/general/mgmt/get-config?keys=server.port"
fi

if docker compose ps --services --status running | grep -qx configuration; then
  check_mtls_authenticated Configuration "$(env_value CONFIGURATION_PORT 8459)" /configuration/mgmt/config
fi

if docker compose ps --services --status running | grep -qx choreographer; then
  check_mtls_authenticated Choreographer "$(env_value CHOREOGRAPHER_PORT 8457)" /choreographer/mgmt/plans
fi

if docker compose ps --services --status running | grep -qx gatekeeper; then
  check_mtls_authenticated Gatekeeper "$(env_value GATEKEEPER_PORT 8449)" /gatekeeper/monitor/echo
fi

if docker compose ps --services --status running | grep -qx gatetunnel; then
  check_mtls_authenticated GateTunnel "$(env_value GATETUNNEL_PORT 8453)" /gatetunnel/monitor/echo
fi

if docker compose ps --services --status running | grep -qx sysmonitor; then
  check_mtls_authenticated SysMonitor "$(env_value SYSMONITOR_PORT 8475)" /sysmonitor/management/status
fi

if docker compose ps --services --status running | grep -qx onboarding; then
  check_mtls Onboarding "$(env_value ONBOARDING_PORT 8435)" /onboarding/echo
fi

if [ "${SMOKE_ALL:-0}" = 1 ]; then
  check_mtls_authenticated Blacklist "$(env_value BLACKLIST_PORT 8464)" /blacklist/monitor/echo
  check_mtls_authenticated TranslationManager "$(env_value TRANSLATION_MANAGER_PORT 8465)" /translation/monitor/echo
  check_mtls_authenticated DeviceQoSEvaluator "$(env_value DEVICE_QOS_EVALUATOR_PORT 8472)" /deviceqosevaluator/monitor/echo

  if docker compose --profile all ps --services --status running | grep -qx serviceorchestration-simple; then
    check_mtls_authenticated SimpleStoreServiceOrchestration "$(env_value SIMPLE_ORCHESTRATION_PORT 8442)" "/serviceorchestration/general/mgmt/get-config?keys=server.port"
  fi

  if docker compose --profile all ps --services --status running | grep -qx authentication; then
    check_mtls Authentication "$(env_value AUTHENTICATION_PORT 8444)" /authentication/monitor/echo
  fi
fi

exit "$failed"
