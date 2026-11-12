#!/bin/sh
# SPDX-License-Identifier: EPL-2.0
# Authentication identities of systems that the fresh primary-source cloud adds (scripts/provision-authentication-
# identities.sh predates them): LocalCloudConfigurator. Idempotent; an existing identity is left unchanged.
set -eu
cd "$(dirname -- "$0")/.."
. scripts/lib-secrets.sh
URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
X=security/x509
curl_sysop() { curl -sS --max-time 15 --cacert $X/ca.crt --cert $X/sysop.crt --key $X/sysop.key -H 'Content-Type: application/json' "$@"; }
token=$(printf '{"systemName":"Sysop","credentials":{"password":"%s"}}' "$(secret ARROWHEAD_SYSOP_PASSWORD)" |
  curl_sysop --data-binary @- "$URL/authentication/identity/login" | jq -er .token)
for pair in LocalCloudConfigurator:AH_PW_LCC SoLocalCloudConfigurator:AH_PW_SOLC; do
  name=${pair%%:*}
  response=$(printf '{"authenticationMethod":"PASSWORD","identities":[{"systemName":"%s","credentials":{"password":"%s"},"sysop":false}]}' \
      "$name" "$(secret "${pair#*:}")" |
    curl_sysop -H "Authorization: Bearer IDENTITY-TOKEN//$token" --data-binary @- "$URL/authentication/mgmt/identities")
  if printf '%s' "$response" | jq -e --arg n "$name" '(.identities? // .entries? // []) | any(.systemName == $n)' >/dev/null 2>&1; then
    echo "identity $name created"
  elif printf '%s' "$response" | jq -e '(.errorMessage? // "") | test("already exist")' >/dev/null 2>&1; then
    echo "identity $name already exists"
  else
    echo "unable to create identity $name: $response" >&2; exit 1
  fi
done
