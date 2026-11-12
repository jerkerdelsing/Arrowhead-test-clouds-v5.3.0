#!/bin/sh
# Operator step of the onboarding procedure: approve a device for onboarding.
#   onboarding-approve-device.sh <DeviceName> <bootstrap-certificate.pem> <System> [<System> ...]
# The device may then enroll with that bootstrap (manufacturer) certificate and obtain certificates and identities for
# exactly the listed systems. Runs as Sysop (operator certificate and identity token, onboardingManagement approve-device).
set -eu
cd "$(dirname "$0")/.."
[ $# -ge 3 ] || { echo "usage: $0 <DeviceName> <bootstrap-certificate.pem> <System> [<System> ...]" >&2; exit 2; }
device=$1; certificate=$2; shift 2
fingerprint=$(openssl x509 -in "$certificate" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr 'A-F' 'a-f')
port=$(sed -n 's/^ONBOARDING_PORT=//p' .env 2>/dev/null | tail -n 1)
. scripts/registry-auth.sh
sysop_login
systems=$(printf '%s\n' "$@" | jq -R . | jq -cs .)
jq -n --arg fp "$fingerprint" --argjson systems "$systems" '{bootstrapFingerprint: $fp, systems: $systems}' |
  curl -fsS $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' -X PUT --data @- \
    "https://127.0.0.1:${port:-8435}/onboarding/mgmt/enrollments/$device" | jq -c '{deviceName, state, approvedSystems, bootstrapFingerprint}'
