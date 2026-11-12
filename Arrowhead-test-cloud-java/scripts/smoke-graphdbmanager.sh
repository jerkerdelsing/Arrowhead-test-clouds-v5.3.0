#!/bin/sh
# End-to-end check of GraphDBManager (DataManager copy on Ontotext GraphDB), as SmokeClient, everything orchestrated:
#   for graphDataHistorian and graphDataProxy: DSO pull for put-data -> PUT a SenML pack -> DSO pull for get-data
#   -> GET it back and compare; list-systems names SmokeClient. Then GraphDB itself: the pack is stored as RDF in the
#   historian named graph, and GraphDB refuses anonymous access. Exit 1 on any failure.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"
. scripts/lib-secrets.sh
CERT_DIR=${CERT_DIR:-security/x509}
env_value() { value=$(sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1); echo "${value:-$2}"; }
bind=$(env_value BIND_ADDRESS 127.0.0.1)
[ "$bind" = 0.0.0.0 ] && bind=127.0.0.1
AUTH_URL="https://$bind:$(env_value AUTHENTICATION_PORT 8444)"
DSO_URL="https://$bind:$(env_value DYNAMIC_ORCHESTRATION_PORT 8441)"
PORT=$(env_value GRAPHDBMANAGER_PORT 8467)
failed=0
ok() { printf '%-64s OK\n' "$1"; }
fail() { printf '%-64s FAILED %s\n' "$1" "${2:-}"; failed=1; }

smoke_curl() {  # the provider's registered address "graphdbmanager" is resolved to the published port
  curl -sS --max-time 15 --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/smoke-client.crt" --key "$CERT_DIR/smoke-client.key" \
    --resolve "graphdbmanager:$PORT:$bind" "$@"
}
token=$(printf '{"systemName":"SmokeClient","credentials":{"password":"%s"}}' "$(secret AH_PW_SMK)" |
  smoke_curl -f -H 'Content-Type: application/json' --data-binary @- "$AUTH_URL/authentication/identity/login" | jq -er .token)
auth="Authorization: Bearer IDENTITY-TOKEN//$token"

# orchestrate <service definition> <operation> -> "<method> <url template>" of the first CERT_AUTH https result
orchestrate() {
  body=$(jq -cn --arg d "$1" --arg o "$2" '{serviceRequirement: {serviceDefinition: $d, operations: [$o],
    versions: ["1.0.0"], interfaceTemplateNames: ["generic_https"]}, orchestrationFlags: {}}')
  smoke_curl -f -H "$auth" -H 'Content-Type: application/json' --data "$body" "$DSO_URL/serviceorchestration/orchestration/pull" |
    jq -er --arg o "$2" '.results[] | select(.providerName == "GraphDBManager") | .interfaces[]
      | select(.protocol == "https" and .policy == "CERT_AUTH") | .properties
      | "\(.operations[$o].method) https://\(.accessAddresses[0]):\(.accessPort)\(.basePath)\(.operations[$o].path)"' | head -n 1
}
expand() { printf '%s' "$1" | sed 's/{systemName}/SmokeClient/; s/{serviceName}/graphSmoke/'; }

stamp=$(date +%s)
value="$stamp.$$"
for service in graphDataHistorian graphDataProxy; do
  put=$(orchestrate "$service" put-data || true)
  get=$(orchestrate "$service" get-data || true)
  list=$(orchestrate "$service" list-systems || true)
  if [ -z "$put" ] || [ -z "$get" ] || [ -z "$list" ]; then
    fail "$service orchestrated (put-data, get-data, list-systems)" "no GraphDBManager result"; continue
  fi
  ok "$service orchestrated (put-data, get-data, list-systems)"
  [ "${put%% *}" = PUT ] && [ "${get%% *}" = GET ] || fail "$service operation methods" "$put / $get"
  pack=$(jq -cn --argjson t "$stamp" --argjson v "$value" '[{bn: "urn:arrowhead:smoke:", bt: $t, n: "graphSmoke", u: "1", v: $v},
    {n: "graphSmokeFlag", vb: true, t: 1}]')
  code=$(smoke_curl -o /dev/null -w '%{http_code}' -X PUT -H "$auth" -H 'Content-Type: application/json' --data "$pack" "$(expand "${put#* }")" || true)
  case "$code" in 200|204) ok "$service put-data (HTTP $code)" ;; *) fail "$service put-data" "HTTP $code" ;; esac
  got=$(smoke_curl -f -H "$auth" "$(expand "${get#* }")" | jq -r '[.. | objects | select(.n == "graphSmoke") | .v] | last // empty' || true)
  # numeric comparison: JSON drops trailing zeros of the fraction
  [ -n "$got" ] && jq -en --argjson a "$got" --argjson b "$value" '$a == $b' >/dev/null && ok "$service get-data round trip" || fail "$service get-data round trip" "got '$got'"
  systems=$(smoke_curl -f -H "$auth" "${list#* }" | jq -c . || true)
  printf '%s' "$systems" | grep -q SmokeClient && ok "$service list-systems" || fail "$service list-systems" "$systems"
done

# GraphDB: SPARQL on the historian graph with GraphDBManager's own GraphDB user. The password comes from secrets/ on the
# host through stdin (a container's secret mount is stale after secrets/ is rewritten) and reaches curl in a netrc file.
query="PREFIX gdm: <https://arrowhead.eu/ns/graphdbmanager#> SELECT (COUNT(?m) AS ?n) FROM <urn:arrowhead:graphdbmanager:historian> WHERE { ?p a gdm:SenMLPack ; gdm:systemName \"SmokeClient\" ; gdm:measurement ?m . ?m gdm:name \"graphSmoke\" ; gdm:value ?v . FILTER(?v = $value) }"
count=$(secret AH_GRAPHDB_PW_GRAPHDBMANAGER | docker compose exec -T -e QUERY="$query" graphdbmanager-graphdb sh -c '
  IFS= read -r pw || [ -n "$pw" ]; n=$(mktemp); printf "machine 127.0.0.1 login graphdbmanager password %s\n" "$pw" > "$n"
  curl -fs --netrc-file "$n" -H "Accept: text/csv" --data-urlencode "query=$QUERY" http://127.0.0.1:7200/repositories/graphdbmanager; rm -f "$n"' |
  tail -n 1 | tr -d '\r' || true)
[ "${count:-0}" -ge 1 ] 2>/dev/null && ok "GraphDB holds the pack as RDF ($count measurement)" || fail "GraphDB holds the pack as RDF" "count '$count'"
anon=$(docker compose exec -T graphdbmanager curl -s -o /dev/null -w '%{http_code}' http://graphdbmanager-graphdb:7200/repositories/graphdbmanager/size || true)
[ "$anon" = 401 ] && ok "GraphDB refuses anonymous access" || fail "GraphDB refuses anonymous access" "HTTP $anon"

exit "$failed"
