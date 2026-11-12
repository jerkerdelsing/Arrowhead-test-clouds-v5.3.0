command -v secret >/dev/null 2>&1 || . "$(dirname -- "$0")/lib-secrets.sh"
# Sourced by the setup scripts. ServiceRegistry runs the outsourced policy behind mutual TLS: every call needs an
# identity token bound to the client certificate. Setup calls run as Sysop (operator certificate sysop.crt):
# Authentication creates Sysop at its first start, so it exists before any other identity is provisioned.
# Defines SYSOP_TLS (curl TLS options) and sysop_login, which sets SYSOP_AUTH (the Authorization header).
CERT_DIR=${CERT_DIR:-security/x509}
_sysop_auth_port=$(sed -n 's/^AUTHENTICATION_PORT=//p' .env 2>/dev/null | tail -n 1)
SYSOP_AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:${_sysop_auth_port:-8444}}
SYSOP_TLS="--cacert $CERT_DIR/ca.crt --cert $CERT_DIR/sysop.crt --key $CERT_DIR/sysop.key"
SYSOP_AUTH=""

sysop_login() {
  _sysop_token=$(curl -fsS --max-time 10 $SYSOP_TLS -H 'Content-Type: application/json' \
    --data "{\"systemName\":\"Sysop\",\"credentials\":{\"password\":\"$(secret ARROWHEAD_SYSOP_PASSWORD)\"}}" \
    "$SYSOP_AUTHENTICATION_URL/authentication/identity/login" 2>/dev/null | jq -r '.token // empty' 2>/dev/null) || return 1
  [ -n "$_sysop_token" ] || return 1
  SYSOP_AUTH="Authorization: Bearer IDENTITY-TOKEN//$_sysop_token"
}
