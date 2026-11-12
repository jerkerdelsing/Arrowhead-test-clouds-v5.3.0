# Per-cloud secrets (security finding H2). Sourced by the setup, provisioning and test scripts (POSIX sh).
#
# secret NAME   prints NAME from the environment, or else from the cloud's .env (mode 600). A missing secret is an
#               error: no script carries a default password any more. scripts/rotate-secrets.sh creates the values.
#
# Secret names (all generated per cloud, random, alphanumeric):
#   AH_PW_<ABBR>                 Authentication identity password of a system (AH_PW_SR, AH_PW_LCM, ...)
#   ARROWHEAD_SYSOP_PASSWORD     the operator identity Sysop
#   DB_ROOT_PSW, DB_AH_OPERATOR_PSW, AH_DB_PW_<USER>   database users
#   X509_STORE_PASSWORD          PKCS#12 keystores and truststores
#   AH_AUTHENTICATION_SECRET_KEY, AH_CONSUMER_AUTHORIZATION_CRYPTO_KEY
#   CONSOLE_PROXY_SECRET         console UI -> API proxy secret (J6)
#   CONSOLE_PASSWORD             LocalCloudManager console login: not in .env (only CONSOLE_PASSWORD_HASH is) but in the
#                                macOS keychain, service arrowhead-console-<project> (J7)
SECRETS_ENV_FILE=${SECRETS_ENV_FILE:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/.env}

secret() {
  eval "_secret_value=\${$1:-}"
  if [ -z "$_secret_value" ] && [ -f "$SECRETS_ENV_FILE" ]; then
    _secret_value=$(sed -n "s/^$1=//p" "$SECRETS_ENV_FILE" | tail -n 1)
  fi
  if [ -z "$_secret_value" ] && [ "$1" = CONSOLE_PASSWORD ] && command -v security >/dev/null 2>&1; then
    _secret_value=$(security find-generic-password -s "arrowhead-console-$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$SECRETS_ENV_FILE" | tail -n 1)" -w 2>/dev/null || true)
  fi
  if [ -z "$_secret_value" ]; then
    echo "secret $1 is not set; run scripts/rotate-secrets.sh" >&2
    return 1
  fi
  printf '%s' "$_secret_value"
}
