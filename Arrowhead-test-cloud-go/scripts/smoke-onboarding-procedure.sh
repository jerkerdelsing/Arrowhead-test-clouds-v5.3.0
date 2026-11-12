#!/bin/sh
# End-to-end test of the Arrowhead 5.2.2 onboarding procedure with the demo device (device-demo/):
#   operator approves Device1 -> the device onboards itself and DemoSensor -> DemoSensor registers, is orchestrated
#   and stores a measurement in DataManager -> the device runs the procedure again and off-boards itself ->
#   everything the procedure created is withdrawn.
set -eu
cd "$(dirname "$0")/.."
. scripts/registry-auth.sh
port() { sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1; }
REGISTRY="https://127.0.0.1:$(port SERVICEREGISTRY_PORT | grep . || echo 8443)"
ONBOARDING="https://127.0.0.1:$(port ONBOARDING_PORT | grep . || echo 8435)"
fail() { echo "FAIL: $*" >&2; exit 1; }
sysop() { sysop_login; curl -fsS $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' "$@"; }
registered() {   # prints "<system> <device>" of DemoSensor in the ServiceRegistry, or nothing
  sysop --data '{"pagination":{"page":0,"size":10},"systemNames":["DemoSensor"]}' "$REGISTRY/serviceregistry/mgmt/systems/query" |
    jq -r '.entries[]? | "\(.name) \(.device.name // "-" | ascii_downcase)"'   # the Java registry upper-cases device names
}
run_device() {
  docker compose --profile demo build -q device-demo >/dev/null
  docker compose --profile demo run --rm -e OFFBOARD="$1" device-demo 2>&1 | tee /dev/stderr | sed -n 's/^SUMMARY //p' | tail -n 1
}

echo "== 1. Operator approves Device1 (bootstrap certificate of the test manufacturer) for DemoSensor"
./scripts/onboarding-approve-device.sh Device1 security/x509/device1-bootstrap.crt DemoSensor

echo "== 2. Device onboards itself and its system, registers and consumes a service"
summary=$(run_device 0)
[ "$(printf '%s' "$summary" | jq -r .result)" = passed ] || fail "onboarding run: $summary"
[ "$(registered)" = "DemoSensor device1" ] || fail "DemoSensor is not registered on Device1: $(registered)"
sysop "$ONBOARDING/onboarding/mgmt/enrollments/Device1" | jq -e '.state == "DEVICE_REGISTERED" and (.systems | length) == 1' >/dev/null ||
  fail "enrollment is not DEVICE_REGISTERED"
echo "   DemoSensor registered on Device1; enrollment DEVICE_REGISTERED"

echo "== 3. Device runs the procedure again (re-issue) and off-boards itself"
summary=$(run_device 1)
[ "$(printf '%s' "$summary" | jq -r .result)" = passed ] || fail "off-boarding run: $summary"
printf '%s' "$summary" | jq -e '.steps[] | select(.step | startswith("7 ")) | .failed == []' >/dev/null || fail "off-boarding reported failures"
[ -z "$(registered)" ] || fail "DemoSensor is still registered: $(registered)"
sysop "$ONBOARDING/onboarding/mgmt/enrollments/Device1" | jq -e '.state == "OFFBOARDED" and (.systems | length) == 0' >/dev/null ||
  fail "enrollment is not OFFBOARDED"
echo "   DemoSensor and Device1 removed, identity refused, certificates revoked; enrollment OFFBOARDED"

echo "== 4. The bootstrap certificate is refused until the operator approves the device again"
code=$(curl -s -o /dev/null -w '%{http_code}' --cacert security/x509/ca.crt --cert security/x509/device1-bootstrap.crt \
  --key security/x509/device1-bootstrap.key -H 'Content-Type: application/json' \
  --data '{"commonName":"Device1.'"$(openssl x509 -in security/x509/ca.crt -noout -subject | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')"'"}' \
  "$ONBOARDING/onboarding/certificate/name")
[ "$code" = 403 ] || fail "off-boarded bootstrap certificate answered $code"
echo "   refused (403)"
echo "Onboarding procedure end-to-end test passed"
