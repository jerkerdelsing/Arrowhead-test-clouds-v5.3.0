#!/bin/sh
# Security regression test (make smoke-security): the findings H1, H2 and H3 of SECURITY-EVALUATION-2026-10-15.md and
# the controls of SECURITY-EVALUATION-JAVA-CLOUD-2026-10-17.md (J1-J14), adapted to GoCloud's native Go systems. The
# same sections as TestCloud's scripts/smoke-security.sh:
#   H1/J6 console: login required, own host name (others redirected), cross-site login refused, LocalCloudManager-go
#       non-root without Docker socket and mTLS-only, Docker proxy whitelist, console proxy and Docker proxy unreachable
#       from the systems (v5.3.0: the primary LocalCloudManager-go behind the loopback console proxy, 2026-11-11)
#   H2  no fixed default credentials: container environments, the former Sysop/LocalCloudManager defaults, .env mode
#   J1  no database: the Go systems keep private JSON state; no MySQL container runs
#   J2  no copy of the cloud CA private key anywhere else in the workspace
#   J3  every container non-root (the Docker proxy too since SOS-8, 2026-11-10), read-only root filesystem, no capabilities, memory and
#       PID limits; writable host mounts only the CA's /crl and the proxy's Docker socket
#   J7  secrets only as files: none in a container's configuration or PID 1 environment, owner-only secret files and
#       bundles, one identity password per system, no plaintext console password, no .env.previous
#   J8  no end-of-life component: Node 22+, Mosquitto 2.0.22+, RabbitMQ 4.1+, nginx 1.30+, Go 1.25+
#   J5  GateTunnel and Gatekeeper run the end-to-end protected AH-GT-1 profile (v5.3.0 without federation: federation
#       is off in both, so no relay session exists; the AH-GT-1 checks run once security/x509/ca-cross.crt exists)
#   J11 no plain-HTTP health port (the Go systems answer health checks over mTLS, ah-probe)
#   J12 a blacklisted system is refused by ServiceRegistry, ConsumerAuthorization, the orchestrators, TranslationManager
#       and DeviceQoSEvaluator
#   J9  ServiceRegistry refuses core/support service definitions from other systems
#   J10 the AMQP broker's epmd and Erlang distribution ports are not reachable from other containers
#   J13 no stray upstream sample keystores, no group/other-readable private keys, no .env.previous
#   J14 no Spring Security generated password in any container log
#   H3/J4 revocation: a probe certificate is accepted by the MQTT broker, the AMQP broker, the relay and every HTTPS
#       service, then revoked and refused by all of them
# Never logs in as a running system: the console login is the operator's, revocation and Blacklist changes run as
# Sysop, the client tests as SmokeClient.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/lib-secrets.sh"
env_value() { value=$(sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1); printf '%s' "${value:-$2}"; }
CERT_DIR=security/x509
CONSOLE_PORT=$(env_value CLOUD_MONITOR_PORT 7490)
CONSOLE_HOST=$(env_value CONSOLE_HOST gocloud-v53.localhost)
CONSOLE="http://$CONSOLE_HOST:$CONSOLE_PORT"
AUTH_URL="https://127.0.0.1:$(env_value AUTHENTICATION_PORT 7444)"
MQTT_PORT=$(env_value MQTT_TLS_PORT 7883)
AMQP_PORT=$(env_value AMQP_TLS_PORT 7671)
RELAY_PORT=${RELAY_PORT:-8893}
CLOUD=$(openssl x509 -in "$CERT_DIR/ca.crt" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p' | cut -d. -f1)
failures=0
check() {  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"; failures=$((failures + 1)); fi
}
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }
# Probe from another system on the shared network. The native Go systems are scratch images without a shell
# (2026-10-17), so the probe runs in RandomDataProducer (Python image); the positive controls prove the probe works.
other=$(docker compose ps -q random-data-producer)
probe_tcp() {
  docker exec "$other" python3 -c 'import socket,sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), 3); print("reachable")
except Exception:
    print("unreachable")' "$1" "$2"
}
# PID 1 environment of a container; for the scratch images (no cat) read by a helper in the container's PID namespace
# that runs as the container's own user (no network, nothing mounted)
environ_of() {
  docker exec "$1" cat /proc/1/environ 2>/dev/null && return 0
  user=$(docker inspect -f '{{.Config.User}}' "$1")
  docker run --rm --pid "container:$1" --network none ${user:+--user "$user"} alpine:3.20 cat /proc/1/environ 2>/dev/null
}

echo "== H1/J6 LocalCloudManager console (LocalCloudManager-go behind the console proxy)"
check "API without session" 401 "$(code "$CONSOLE/api/overview")"
# a foreign host name (DNS rebinding, or 127.0.0.1) never reaches the API: the console proxy redirects to the console's own name (J6)
check "foreign Host (DNS rebinding) is redirected away" 308 "$(code -H "Host: attacker.example:$CONSOLE_PORT" "$CONSOLE/api/overview")"
check "127.0.0.1 is redirected to $CONSOLE_HOST" 308 "$(code "http://127.0.0.1:$CONSOLE_PORT/")"
# LocalCloudManager-go decodes any login body (no JSON content-type requirement, unlike the 5.2 console); a cross-site form
# post carries its Origin and is refused before the password is checked
check "cross-site form login (text/plain, foreign Origin) refused" 403 "$(code -H 'Origin: http://attacker.example' \
  -H 'Content-Type: text/plain' --data '{"password":"x"}' "$CONSOLE/api/session")"
check "foreign Origin" 403 "$(code -H 'Origin: http://attacker.example' -X POST "$CONSOLE/api/session")"
check "wrong console password" 401 "$(code -H 'Content-Type: application/json' --data '{"password":"wrong"}' "$CONSOLE/api/session")"
jar=$(mktemp)
check "console login" 204 "$(code -c "$jar" -H 'Content-Type: application/json' \
  --data "{\"password\":\"$(secret CONSOLE_PASSWORD)\"}" "$CONSOLE/api/session")"
grep -q "ah_console" "$jar" && cookie_flags=$(grep -c "#HttpOnly_" "$jar") || cookie_flags=0
check "session cookie is HttpOnly" 1 "$cookie_flags"
check "API with session" 200 "$(code -b "$jar" "$CONSOLE/api/overview")"
check "console reaches Docker through the proxy (launcher socket bridge)" true \
  "$(curl -s --max-time 15 -b "$jar" "$CONSOLE/api/overview" | jq -r '.cloud.dockerReachable')"
check "session cookie only for $CONSOLE_HOST" "#HttpOnly_$CONSOLE_HOST" "$(grep ah_console "$jar" | awk '{print $1}')"
check "logout" 200 "$(code -b "$jar" -X DELETE "$CONSOLE/api/session")"
check "API after logout" 401 "$(code -b "$jar" "$CONSOLE/api/overview")"
rm -f "$jar"
lcm=$(docker compose ps -q localcloudmanager)
check "LocalCloudManager runs as non-root" 65532:65532 "$(docker inspect -f '{{.Config.User}}' "$lcm")"
check "LocalCloudManager has no Docker socket" absent \
  "$(docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' "$lcm" | grep -q 'docker.sock' && echo present || echo absent)"
# the Docker proxy's allowlist, from a throw-away client on the proxy's internal network (LocalCloudManager-go is a
# scratch image without an interpreter); the producer image has Python
dnet=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$(docker compose ps -q docker-proxy)" | head -n 1)
proxy_probe() {
  docker run --rm --platform linux/amd64 --network "$dnet" --read-only --cap-drop ALL --entrypoint python3 \
    "$(docker inspect -f '{{.Config.Image}}' "$other")" -c 'import http.client,sys
try:
    c = http.client.HTTPConnection("docker-proxy", 2375, timeout=5); c.request(sys.argv[2], sys.argv[1]); print(c.getresponse().status)
except Exception:
    print("unreachable")' "$1" "$2" 2>/dev/null
}
check "proxy refuses container create" 403 "$(proxy_probe /containers/create POST)"
check "proxy refuses image listing" 403 "$(proxy_probe /images/json GET)"
check "proxy lists project containers" 200 "$(proxy_probe /containers/json GET)"
check "proxy unreachable from other systems" unreachable "$(probe_tcp docker-proxy 2375)"
check "console proxy unreachable from other systems (J6)" unreachable "$(probe_tcp console-proxy 8490)"
# LocalCloudManager-go serves its console only with mutual TLS: a client without a cloud certificate gets no answer
lcm_tls=$(docker exec "$other" python3 -c 'import socket,ssl
c = ssl.create_default_context(cafile="/certs/ca.crt"); c.check_hostname = False
try:
    s = c.wrap_socket(socket.create_connection(("localcloudmanager", 8480), 5))
    s.sendall(b"GET /api/session HTTP/1.0\r\nHost: localcloudmanager\r\n\r\n"); print("accepted" if s.recv(64) else "refused")
except Exception:
    print("refused")')
check "LocalCloudManager refuses a client without certificate (mTLS)" refused "$lcm_tls"
check "probe reaches the ServiceRegistry from other systems" reachable "$(probe_tcp serviceregistry 8443)"

echo "== H2 credentials"
defaults=0
for id in $(docker compose ps -q); do
  if docker inspect "$id" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -Eq -- '-test-52|=123456$|IJhl6xFr31p7g4l|xFNHbh2mQyIp1gmimeTC'; then
    defaults=$((defaults + 1))
  fi
done
check "containers with a former default credential" 0 "$defaults"
change_default() {  # identity/change from the former default: 401 means the default no longer works (no login)
  code --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/$2.crt" --key "$CERT_DIR/$2.key" -H 'Content-Type: application/json' \
    --data "{\"systemName\":\"$1\",\"credentials\":{\"password\":\"$3\"},\"newCredentials\":{\"password\":\"$3\"}}" \
    "$AUTH_URL/authentication/identity/change"
}
check "former Sysop default refused" 401 "$(change_default Sysop sysop xFNHbh2mQyIp1gmimeTC)"
check "former LocalCloudManager default refused" 401 "$(change_default LocalCloudManager local-cloud-manager LCM-test-52)"
check "former ServiceRegistry seed refused" 401 "$(change_default ServiceRegistry serviceregistry 123456)"
check ".env readable by the owner only" 600 "$(stat -f %Lp .env 2>/dev/null || stat -c %a .env)"

echo "== J1 no database"
# Exception (2026-10-24): the swapped-in Java Blacklist (make swap-java-blacklist) has its own database, as TestCloud's
# Java systems (J1 there): reachable only on its internal network, with the TestCloud hardening (J3/J7 below)
check "running database containers (besides blacklist-java-db)" 0 "$(docker compose ps --services | grep -- '-db$' | grep -cv '^blacklist-java-db$' || true)"
if db=$(docker compose ps -q blacklist-java-db 2>/dev/null) && [ -n "$db" ]; then
  check "blacklist-java-db only on its internal network" "db-blacklist-java" \
    "$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$db" | sed 's/^.*_//' | tr -d '\n')"
fi

echo "== J2 custody of the cloud CA key"
ca_store=security/bundles-go/certificate-authority/ca.key
ca_pub=$(openssl pkey -in "$ca_store" -pubout 2>/dev/null | shasum -a 256 | cut -c1-16)
copies=0
for f in $(find .. \( -name '*.key' -o -name '*.pem' \) -type f -not -path '*/node_modules/*' 2>/dev/null); do
  case "$f" in ../"$(basename "$ROOT_DIR")"/security/x509/ca.key|../"$(basename "$ROOT_DIR")"/$ca_store) continue ;; esac
  [ "$(openssl pkey -in "$f" -pubout 2>/dev/null | shasum -a 256 | cut -c1-16)" = "$ca_pub" ] && { echo "        CA key copy: $f"; copies=$((copies + 1)); }
done
check "no copy of the CA key outside this cloud's CA store" 0 "$copies"

echo "== J3 container hardening"
# every container: non-root (the Docker proxy too since SOS-8: group 0 is enough for the socket), read-only root
# filesystem, all capabilities dropped and none added, no-new-privileges, memory and PID limits; writable host
# mounts only the CertificateAuthority's /crl and the proxy's Docker socket
weak=""; writable=""
for service in $(docker compose ps --services); do
  id=$(docker compose ps -q "$service")
  facts=$(docker inspect -f '{{.Config.User}}|{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.CapDrop}}|{{.HostConfig.CapAdd}}|{{.HostConfig.SecurityOpt}}|{{.HostConfig.Memory}}|{{.HostConfig.PidsLimit}}' "$id")
  user=${facts%%|*}
  # SOS-8 (2026-11-10): the Docker proxy is no longer exempt (node user 1000, group 0 opens the socket); root is the uid
  case "${user%%:*}" in ""|0|root) weak="$weak $service(root)" ;; esac
  case "$facts" in *"|true|[ALL]|[]|"*no-new-privileges*) ;; *) weak="$weak $service(${facts#*|})" ;; esac
  case "$facts" in *"|0|"*|*"|<nil>"|*"|0") weak="$weak $service(no memory or PID limit)" ;; esac
  for mount in $(docker inspect -f '{{range .Mounts}}{{if and (eq .Type "bind") .RW}}{{println .Destination}}{{end}}{{end}}' "$id"); do
    case "$service:$mount" in certificate-authority:/crl|docker-proxy:/var/run/docker.sock) ;; *) writable="$writable $service:$mount" ;; esac
  done
done
check "containers that run as root, write their root filesystem, keep capabilities or have no limits" "" "$weak"
check "writable host mounts other than the CA's /crl and the proxy's socket" "" "$writable"

echo "== J7 secrets only as files"
values=$(mktemp); chmod 600 "$values"
# every secret of the cloud (also the identity passwords that reach the Go systems only as bundle files)
sed -n -E 's/^(AH_PW_[A-Z0-9_]+|AH_STORE_PW_[A-Z0-9_]+|ARROWHEAD_SYSOP_PASSWORD|AH_AUTHENTICATION_SECRET_KEY|AH_CONSUMER_AUTHORIZATION_CRYPTO_KEY|CONSOLE_PROXY_SECRET|CONSOLE_PASSWORD_HASH)=(.{8,})$/\2/p' .env > "$values"
in_config=0; in_environ=0; unchecked=0
for id in $(docker compose ps -q); do
  docker inspect "$id" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qFf "$values" && in_config=$((in_config + 1))
  if environ=$(environ_of "$id"); then
    printf '%s' "$environ" | tr '\0' '\n' | grep -qFf "$values" && in_environ=$((in_environ + 1))
  else
    unchecked=$((unchecked + 1))
  fi
done
rm -f "$values"
check "containers with a secret in their configuration (docker inspect)" 0 "$in_config"
check "containers with a secret in their PID 1 environment" 0 "$in_environ"
check "containers whose PID 1 environment could not be read" 0 "$unchecked"
check "secrets/ readable by the owner only" 700 "$(stat -f %Lp secrets 2>/dev/null || stat -c %a secrets)"
check "secret files readable by the owner only" 600 "$(stat -f %Lp secrets/* 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "Go credential bundles readable by the owner only" 600 \
  "$(find security/bundles-go -type f -exec stat -f %Lp {} \; | sort -u | tr '\n' ' ' | sed 's/ $//')"
[ -d security/bundles-java ] && check "Java credential bundles readable by the owner only" 600 \
  "$(find security/bundles-java -type f -exec stat -f %Lp {} \; | sort -u | tr '\n' ' ' | sed 's/ $//')"
check "no plaintext console password in .env" 0 "$(grep -cE '^CONSOLE_PASSWORD=' .env || true)"
# The Go systems use PEM keys; X509_STORE_PASSWORD protects only the java-legacy rollback keystores (runtime/), which
# no running container mounts. A swapped-in Java system mounts keystores with its own password (TestCloud: one keystore
# password per system), from its credential bundle in security/bundles-java.
p12=0; shared=0
store_password=$(secret X509_STORE_PASSWORD)
for id in $(docker compose ps -q); do
  for source in $(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{println .Source}}{{end}}{{end}}' "$id"); do
    [ -e "$source" ] || continue
    for store in $(find "$source" -name '*.p12' 2>/dev/null); do
      case "$store" in "$ROOT_DIR"/security/bundles-java/*) ;; *) p12=$((p12 + 1)) ;; esac
      openssl pkcs12 -in "$store" -passin "pass:$store_password" -nokeys -noout 2>/dev/null && shared=$((shared + 1))
    done
  done
done
check "bind-mounted PKCS#12 keystores outside the Java credential bundles" 0 "$p12"
check "bind-mounted keystores protected by the shared X509_STORE_PASSWORD" 0 "$shared"
identities=$(grep -c '^AH_PW_' .env)
check "one distinct identity password per system ($identities systems)" "$identities" "$(sed -n 's/^AH_PW_[A-Z0-9_]*=//p' .env | sort -u | wc -l | tr -d ' ')"
check "no .env.previous kept after a verified rotation" absent "$([ -e .env.previous ] && echo present || echo absent)"

echo "== J8 supported component versions"
at_least() { [ -n "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ] && echo "$2" || echo "older than $1: ${2:-unknown}"; }
node_proxy=$(docker compose exec -T docker-proxy node -p process.versions.node 2>/dev/null)
check "Docker proxy on Node 22+ ($node_proxy)" "$node_proxy" "$(at_least 22 "$node_proxy")"
mosquitto=$(docker compose exec -T mqtt-broker /usr/sbin/mosquitto -h 2>&1 | sed -n 's/^mosquitto version \([0-9.]*\).*/\1/p')
check "Mosquitto 2.0.22+ ($mosquitto)" "$mosquitto" "$(at_least 2.0.22 "$mosquitto")"
rabbitmq=$(docker compose exec -T amqp-broker rabbitmqctl -q version 2>/dev/null | tr -d '\r')
check "RabbitMQ 4.1+ ($rabbitmq)" "$rabbitmq" "$(at_least 4.1 "$rabbitmq")"
nginx=$(docker compose exec -T console-proxy nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')
check "console proxy on nginx 1.30+ ($nginx)" "$nginx" "$(at_least 1.30 "$nginx")"
# the Go version recorded in a deployed binary (v5.3.0: the images of generator/build.sh)
golang=""
bin_dir=$(mktemp -d)
if command -v go >/dev/null 2>&1 && docker compose cp blacklist:/usr/local/bin/Blacklist "$bin_dir/Blacklist" >/dev/null 2>&1; then
  golang=$(go version "$bin_dir/Blacklist" 2>/dev/null | sed -n 's/.*: go\([0-9.]*\).*/\1/p')
fi
rm -rf "$bin_dir"
check "Go systems built with Go 1.25+ ($golang)" "$golang" "$(at_least 1.25 "$golang")"

echo "== J5 end-to-end protected inter-cloud sessions"
. "$ROOT_DIR/scripts/registry-auth.sh"
sysop_login
for system in gatetunnel:$(env_value GATETUNNEL_PORT 7453) gatekeeper:$(env_value GATEKEEPER_PORT 7449); do
  name=${system%%:*}
  if [ -f "$CERT_DIR/ca-cross.crt" ]; then
    profile=$(curl -s --max-time 15 $SYSOP_TLS -H "$SYSOP_AUTH" "https://127.0.0.1:${system#*:}/$name/mgmt/status" | jq -r '"\(.relay.profile)/\(.relay.endToEndEncrypted)"')
    check "$name relay profile AH-GT-1 with end-to-end encryption" "ah-gt-1/true" "$profile"
  else
    # v5.3.0 without federation: no relay connection, no inter-cloud session can be opened
    status=$(curl -s --max-time 15 $SYSOP_TLS -H "$SYSOP_AUTH" "https://127.0.0.1:${system#*:}/$name/mgmt/status" | jq -r '"\(.errorCode) \(.errorMessage)"')
    check "$name federation off (no relay session)" "503 Federation is not enabled/configured" "$status"
    check "$name runtime federationEnabled" false "$(jq -r .federationEnabled "runtime-go/$name.json")"
  fi
done

echo "== J11 no plain-HTTP health ports"
for target in gatekeeper:8480 gatetunnel:8481 sysmonitor:8482 certificate-authority:8483; do
  check "${target%%:*} port ${target#*:} unreachable from other systems" unreachable "$(probe_tcp "${target%%:*}" "${target#*:}")"
done
check "positive control: gatekeeper mTLS port 8449 reachable" reachable "$(probe_tcp gatekeeper 8449)"

echo "== J12 Blacklist enforcement"
# SmokeClient is blacklisted for the test only; the entry is removed again even when the test stops early
blacklist_call() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 $SYSOP_TLS -H "$SYSOP_AUTH" "$@"; }
BLACKLIST_URL="https://127.0.0.1:$(env_value BLACKLIST_PORT 7464)/blacklist/mgmt"
trap 'blacklist_call -X DELETE "$BLACKLIST_URL/remove?names=SmokeClient" >/dev/null' EXIT
smoke_token=$(curl -fsS --max-time 15 --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/smoke-client.crt" --key "$CERT_DIR/smoke-client.key" \
  -H 'Content-Type: application/json' --data "{\"systemName\":\"SmokeClient\",\"credentials\":{\"password\":\"$(secret AH_PW_SMK)\"}}" \
  "$AUTH_URL/authentication/identity/login" | jq -r '.token')
smoke_echo() { code --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/smoke-client.crt" --key "$CERT_DIR/smoke-client.key" \
  -H "Authorization: Bearer IDENTITY-TOKEN//$smoke_token" "https://127.0.0.1:$1"; }
# <port>/<path>=<status once served> (the Go orchestrators have an echo, unlike the Java ones)
FILTERED="$(env_value SERVICEREGISTRY_PORT 7443)/serviceregistry/monitor/echo=200 $(env_value CONSUMER_AUTHORIZATION_PORT 7445)/consumerauthorization/monitor/echo=200
$(env_value DYNAMIC_ORCHESTRATION_PORT 7441)/serviceorchestration/monitor/echo=200 $(env_value SIMPLE_ORCHESTRATION_PORT 7442)/serviceorchestration/monitor/echo=200
$(env_value TRANSLATION_MANAGER_PORT 7465)/translation/monitor/echo=200 $(env_value DEVICE_QOS_EVALUATOR_PORT 7472)/deviceqosevaluator/monitor/echo=200"
for target in $FILTERED; do check "SmokeClient served before the test at port ${target%%/*}" "${target##*=}" "$(smoke_echo "${target%=*}")"; done
check "blacklist SmokeClient" 201 "$(blacklist_call -H 'Content-Type: application/json' \
  --data '{"entities":[{"systemName":"SmokeClient","reason":"smoke-security J12"}]}' "$BLACKLIST_URL/create")"
for target in $FILTERED; do check "blacklisted SmokeClient refused at port ${target%%/*}" 403 "$(smoke_echo "${target%=*}")"; done
check "remove SmokeClient from the blacklist" 200 "$(blacklist_call -X DELETE "$BLACKLIST_URL/remove?names=SmokeClient")"
for target in $FILTERED; do check "SmokeClient served again at port ${target%%/*}" "${target##*=}" "$(smoke_echo "${target%=*}")"; done
trap - EXIT

echo "== J9 reserved service definitions"
for definition in certificateSigning identity serviceDiscovery; do
  # the payload is built outside "$(...)": /bin/sh (bash 3.2) mis-parses escaped quotes inside it
  payload=$(jq -cn --arg d "$definition" '{serviceDefinitionName: $d, version: "1.0.0", interfaces: [{templateName: "generic_https",
    protocol: "https", policy: "CERT_AUTH", properties: {accessAddresses: ["probe.example"], accessPort: 443, basePath: "/probe",
    operations: {op: {method: "POST", path: "/op"}}}}]}')
  check "SmokeClient cannot register $definition" 403 "$(code --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/smoke-client.crt" \
    --key "$CERT_DIR/smoke-client.key" -H "Authorization: Bearer IDENTITY-TOKEN//$smoke_token" -H 'Content-Type: application/json' \
    --data "$payload" "https://127.0.0.1:$(env_value SERVICEREGISTRY_PORT 7443)/serviceregistry/service-discovery/register")"
done

echo "== J10 Erlang distribution of the AMQP broker"
for port in 4369 25672; do
  check "AMQP broker port $port unreachable from other systems" unreachable "$(probe_tcp amqp-broker "$port")"
done
check "positive control: AMQPS 5671 reachable" reachable "$(probe_tcp amqp-broker 5671)"

echo "== J13 host key hygiene"
check "no stray upstream sample keystores (runtime/*/config/certificte)" 0 "$(find runtime -type d -name certificte 2>/dev/null | wc -l | tr -d ' ')"
check "no private key or keystore readable by group or others" 0 \
  "$(find security runtime secrets \( -name '*.key' -o -name '*.p12' \) -perm +044 2>/dev/null | wc -l | tr -d ' ')"
check "no .env.previous with an earlier secret set" absent "$( [ -e .env.previous ] && echo present || echo absent)"

echo "== J14 no generated Spring Security password"
generated=0
for id in $(docker compose ps -q); do
  docker logs "$id" 2>&1 | grep -q "Using generated security password" && generated=$((generated + 1))
done
check "containers that logged a generated password" 0 "$generated"

echo "== H3/J4 revocation at the brokers, the relay and every HTTPS service"
# every HTTPS system of the cloud (host ports): ServiceRegistry, the orchestrators, ConsumerAuthorization, Authentication,
# Blacklist, TranslationManager, DeviceQoSEvaluator, Onboarding, DataManager, TimeManager, EventHandler, PDE,
# Configuration, Choreographer, SysMonitor, Gatekeeper, GateTunnel, AIGym, CertificateAuthority
HTTPS_PORTS="7443 7441 7442 7445 7444 7464 7465 7472 7435 7461 7463 7455 7432 7459 7457 7475 7449 7453 7478 7448"
work=$(mktemp -d)
openssl req -new -newkey rsa:2048 -nodes -keyout "$work/probe.key" -out "$work/probe.csr" \
  -subj "/C=SE/O=Company/OU=$CLOUD/CN=RevocationProbe.$CLOUD.Company.arrowhead.eu/dnQualifier=sy" 2>/dev/null
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n' > "$work/probe.ext"
openssl x509 -req -in "$work/probe.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAserial "$work/probe.srl" \
  -CAcreateserial -days 1 -extfile "$work/probe.ext" -out "$work/probe.crt" 2>/dev/null
# v5.3.0 without federation: the relay checks run once this cloud's CA is cross-signed (security/x509/ca-cross.crt)
FEDERATED=no; [ -f "$CERT_DIR/ca-cross.crt" ] && FEDERATED=yes
[ $FEDERATED = yes ] && cat "$work/probe.crt" "$CERT_DIR/ca-cross.crt" > "$work/probe-chain.crt"
handshake() {  # handshake <port> <ca file> <chain> -> accepted | refused
  out=$(openssl s_client -connect "127.0.0.1:$1" -tls1_2 -CAfile "$2" -cert "$3" -cert_chain "$3" -key "$work/probe.key" \
    </dev/null 2>&1 || true)
  if printf '%s' "$out" | grep -q "alert"; then echo refused
  elif printf '%s' "$out" | grep -q "Verify return code: 0"; then echo accepted
  else echo error; fi
}
https_probe() {  # https_probe <port> -> accepted (any HTTP answer, e.g. 401 without a token) | refused (no HTTP answer)
  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$CERT_DIR/ca.crt" --cert "$work/probe.crt" \
    --key "$work/probe.key" "https://127.0.0.1:$1/" || true)
  if [ "$status" = 000 ]; then echo refused; else echo accepted; fi
}
check "MQTT broker accepts the probe" accepted "$(handshake "$MQTT_PORT" "$CERT_DIR/ca.crt" "$work/probe.crt")"
check "AMQP broker accepts the probe" accepted "$(handshake "$AMQP_PORT" "$CERT_DIR/ca.crt" "$work/probe.crt")"
[ $FEDERATED = yes ] && check "relay accepts the probe" accepted "$(handshake "$RELAY_PORT" "$CERT_DIR/org-ca.crt" "$work/probe-chain.crt")"
for port in $HTTPS_PORTS; do check "HTTPS $port accepts the probe" accepted "$(https_probe "$port")"; done
./scripts/revoke-certificate.sh "$work/probe.crt" | sed 's/^/  /'
sleep 12  # crl-watch.sh polls every 10 s
check "MQTT broker refuses the revoked probe" refused "$(handshake "$MQTT_PORT" "$CERT_DIR/ca.crt" "$work/probe.crt")"
check "AMQP broker refuses the revoked probe" refused "$(handshake "$AMQP_PORT" "$CERT_DIR/ca.crt" "$work/probe.crt")"
[ $FEDERATED = yes ] && check "relay refuses the revoked probe" refused "$(handshake "$RELAY_PORT" "$CERT_DIR/org-ca.crt" "$work/probe-chain.crt")"
# the Go systems read the CRL file on each handshake (crlFile, SERVER_SSL_CRL_FILE)
for port in $HTTPS_PORTS; do
  waited=0
  while [ "$(https_probe "$port")" != refused ] && [ "$waited" -lt 60 ]; do sleep 5; waited=$((waited + 5)); done
  check "HTTPS $port refuses the revoked probe" refused "$(https_probe "$port")"
done
rm -f "$work/probe.key" "$work/probe.csr" "$work/probe.ext" "$work/probe.srl" "$work/probe.crt" "$work/probe-chain.crt"
rmdir "$work"

if [ "$failures" -eq 0 ]; then echo "Security regression test passed"; else echo "Security regression test: $failures failure(s)"; exit 1; fi
