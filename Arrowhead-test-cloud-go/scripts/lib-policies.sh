command -v secret >/dev/null 2>&1 || . "$(dirname -- "$0")/lib-secrets.sh"
# Shared ConsumerAuthorization helper for the configure-*-policy scripts (POSIX sh; source it).
#
# apply_policies <json>   <json> is {"list":[policy, ...]} as accepted by authorization/mgmt/grant.
#
# ConsumerAuthorization keeps one management policy per cloud/provider/target type/target and rejects a whole
# grant batch when any policy in it already exists. So every policy is applied on its own: revoke it, grant it,
# and require the exact instance id (MGMT|<cloud or LOCAL>|provider|targetType|target) in the response.
# Re-running is therefore safe and always leaves the policies exactly as declared.
#
# POLICY_DRY_RUN=1 prints each declared policy as one JSON line instead of applying it (used by check-policies.sh).

# The policies are managed as the operator Sysop (J6): no running system's identity is used, so the console identity
# LocalCloudManager needs no authorization-management right, and its token is never replaced by a login.
policy_token() {
  if [ -z "${POLICY_TOKEN:-}" ]; then
    POLICY_TOKEN=$(curl -fsS --cacert "$CERT_DIR/ca.crt" \
      --cert "$CERT_DIR/sysop.crt" --key "$CERT_DIR/sysop.key" \
      -H 'Content-Type: application/json' \
      --data "{\"systemName\":\"Sysop\",\"credentials\":{\"password\":\"$(secret ARROWHEAD_SYSOP_PASSWORD)\"}}" \
      "$AUTHENTICATION_URL/authentication/identity/login" | jq -er '.token')
  fi
}
policy_call() {
  curl -sS --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/sysop.crt" --key "$CERT_DIR/sysop.key" \
    -H "Authorization: Bearer IDENTITY-TOKEN//$POLICY_TOKEN" -H 'Content-Type: application/json' "$@"
}
apply_policies() {
  policies=$(printf '%s' "$1" | jq -c '.list[]')
  if [ "${POLICY_DRY_RUN:-0}" = 1 ]; then
    printf '%s\n' "$policies"
    return 0
  fi
  policy_token
  printf '%s\n' "$policies" | while IFS= read -r policy; do
    # a policy for consumers of a neighbour cloud carries "cloud": "<Cloud>|<Organization>" instead of LOCAL
    id=$(printf '%s' "$policy" | jq -r '"MGMT|\(.cloud // "LOCAL")|\(.provider)|\(.targetType)|\(.target)"')
    encoded=$(printf '%s' "$id" | sed 's/|/%7C/g')
    # unknown instance ids are ignored by revoke
    policy_call -X DELETE "$AUTHORIZATION_URL/consumerauthorization/authorization/mgmt/revoke?instanceIds=$encoded" >/dev/null
    response=$(policy_call --data "{\"list\":[$policy]}" "$AUTHORIZATION_URL/consumerauthorization/authorization/mgmt/grant")
    if printf '%s' "$response" | jq -e --arg id "$id" '.entries? // [] | any(.instanceId == $id)' >/dev/null 2>&1; then
      echo "  policy $id configured"
    else
      echo "Unable to configure policy $id: $response" >&2
      exit 1
    fi
  done
}
