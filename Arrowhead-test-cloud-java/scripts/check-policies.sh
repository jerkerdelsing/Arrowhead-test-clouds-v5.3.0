#!/bin/sh
# Compares the ConsumerAuthorization management policies declared by the configure-*-policy scripts with those
# stored in ConsumerAuthorization. Reports missing policies, policies whose consumer lists differ, and stored
# policies that no script declares. Read-only; exits 1 when a declared policy is missing or differs.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AUTHORIZATION_URL=${CONSUMER_AUTHORIZATION_URL:-https://127.0.0.1:8445}
AUTHENTICATION_URL=${AUTHENTICATION_URL:-https://127.0.0.1:8444}
CERT_DIR=${CERT_DIR:-security/x509}
. "$SCRIPT_DIR/lib-policies.sh"

declared=$(for script in "$SCRIPT_DIR"/configure-*.sh; do
  grep -q 'lib-policies.sh' "$script" || continue
  # dry run: every apply_policies call prints its policies instead of applying them
  POLICY_DRY_RUN=1 CONSUMER_AUTHORIZATION_URL=$AUTHORIZATION_URL AUTHENTICATION_URL=$AUTHENTICATION_URL "$script" 2>/dev/null \
    | grep '^{' | jq -c --arg s "$(basename "$script")" '. + {script: $s}'
done | jq -s 'unique_by([.provider, .targetType, .target, .script])')

policy_token
stored=$(policy_call --data '{"pagination":{"page":0,"size":1000},"level":"MGMT"}' \
  "$AUTHORIZATION_URL/consumerauthorization/authorization/mgmt/query" | jq '.entries')

jq -rn --argjson declared "$declared" --argjson stored "$stored" '
  def id: "MGMT|LOCAL|\(.provider)|\(.targetType)|\(.target)";
  def norm(p): {type: (p.policyType // ""), list: ((p.policyList // []) | sort)};
  def shape: {default: norm(.defaultPolicy), scoped: ((.scopedPolicies // {}) | with_entries(.value = norm(.value)))};
  ($stored | map({key: .instanceId, value: .}) | from_entries) as $have
  | ($declared | group_by(id) | map(select(length > 1)) | map("OVERLAP  \(.[0] | id) declared by \(map(.script) | join(", "))")) as $overlaps
  | [$declared[] | id as $i
     | if $have[$i] == null then "MISSING  \($i)  (\(.script))"
       elif (shape) != ($have[$i] | shape) then "DIFFERS  \($i)  (\(.script)): declared \(shape | tojson), stored \($have[$i] | shape | tojson)"
       else empty end] as $problems
  | ($declared | map(id)) as $ids
  | [$stored[] | select(.instanceId as $i | $ids | index($i) | not) | "EXTRA    \(.instanceId)  (no script declares it)"] as $extra
  | ($overlaps + $problems + $extra)[],
    "declared \($declared | length), stored \($stored | length), missing or different \($problems | length), extra \($extra | length)"
' | tee /dev/stderr | grep -q '^MISSING\|^DIFFERS\|^OVERLAP' && exit 1
exit 0
