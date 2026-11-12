#!/bin/sh
# Security regression test for the findings H1, H2 and H3 of SECURITY-EVALUATION-2026-10-15.md and J1, J2 of
# SECURITY-EVALUATION-JAVA-CLOUD-2026-10-17.md (J1, J2, J4, J5, J7, J8; make smoke-security).
#   H1  console: login required, foreign Host/Origin refused, API non-root without Docker socket, proxy whitelist
#   H2  no fixed default credentials: container environments, the former Sysop/LocalCloudManager defaults, .env mode
#   J5  GateTunnel and Gatekeeper run the end-to-end protected AH-GT-1 profile
#   J11 the plain-HTTP health ports of the Java support runtime are not reachable from other containers
#   J12 a blacklisted system is refused by ServiceRegistry, ConsumerAuthorization, the orchestrators, TranslationManager
#       and DeviceQoSEvaluator
#   J13 no stray sample keystores, no group/other-readable private keys, no .env.previous
#   J14 no Spring Security generated password in any container log
#   J9  ServiceRegistry refuses core/support service definitions from other systems
#   J10 the AMQP broker's epmd and Erlang distribution ports are not reachable from other containers
#   J1  per-database root and system users, no shared ah-operator, databases unreachable from other systems
#   J2  no copy of the cloud CA private key anywhere else in the workspace
#   J15 no container mounts security/x509, security/ca or another system's credentials; CA signing keys only in
#       security/ca and, for the cloud CA, the CertificateAuthority's bundle
#   J16 the CRL is valid for at least 24 more hours, published with CRL_VALIDITY_HOURS >= 72 by a running CA
#   J18 /health on the mTLS ports of the Java support runtime returns only status and system name without a token
#   J19 no container holds more than one identity password, or the Sysop/SmokeClient password; no seed copies
#   J23 Sysop is the only sysop identity; LocalCloudManager relies on explicit grants
#   LC  localCloudConfiguration is granted to LocalCloudManager only; LocalCloudConfigurator may verify its consumers
#   SoLC soLocalCloudConfiguration is granted to LocalCloudManager only; SoLocalCloudConfigurator only reads designs
#   J3  every container non-root (the Docker proxy too since SOS-8, 2026-11-10), read-only root filesystem, no capabilities, memory and
#       PID limits; writable host mounts only the CA's /crl and the proxy's Docker socket
#   J7  secrets only as files: none in a container's configuration or in its PID 1 environment, owner-only secret
#       files, one keystore password per system, no plaintext console password and no .env.previous
#   J8  no end-of-life component: MySQL 8.4 LTS, Node 22+, Mosquitto 2.0.22+, RabbitMQ 4.1+, nginx 1.30+
#   H3  revocation: a probe certificate is accepted by the MQTT broker, the AMQP broker and the relay, then revoked
#       and refused by all three
#   J4  the same probe is accepted, then refused after revocation, by every HTTPS service of the cloud
# Never logs in as a running system: the console login is the operator's, revocation runs as Sysop.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/lib-secrets.sh"
env_value() { value=$(sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1); printf '%s' "${value:-$2}"; }
CERT_DIR=security/x509
CA_KEYS=security/ca  # CA signing keys (J15)
CONSOLE_HOST=$(env_value CONSOLE_HOST testcloud.localhost)
CONSOLE="http://$CONSOLE_HOST:$(env_value CLOUD_MONITOR_PORT 8490)"
AUTH_URL="https://127.0.0.1:$(env_value AUTHENTICATION_PORT 8444)"
MQTT_PORT=$(env_value MQTT_TLS_PORT 8883)
AMQP_PORT=$(env_value AMQP_TLS_PORT 5671)
RELAY_PORT=${RELAY_PORT:-8893}
CLOUD=$(openssl x509 -in "$CERT_DIR/ca.crt" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p' | cut -d. -f1)
failures=0
check() {  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"; failures=$((failures + 1)); fi
}
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }

echo "== H1 LocalCloudManager console"
check "API without session" 401 "$(code "$CONSOLE/api/overview")"
# a foreign host name (DNS rebinding) never reaches the API (J6). Since 2026-11-09 the Spring LocalCloudManager serves
# console and API itself and refuses a Host outside CONSOLE_ALLOWED_HOSTS (the former nginx UI redirected instead).
check "foreign Host (DNS rebinding) is refused" 403 "$(code -H 'Host: attacker.example:8490' "$CONSOLE/api/overview")"
check "loopback console name 127.0.0.1 is served" 200 "$(code "http://127.0.0.1:$(env_value CLOUD_MONITOR_PORT 8490)/")"
check "login refuses a non-JSON body (cross-site form)" 415 "$(code -H 'Content-Type: text/plain' --data '{"password":"x"}' "$CONSOLE/api/session")"
check "foreign Origin" 403 "$(code -H 'Origin: http://attacker.example' -X POST "$CONSOLE/api/session")"
check "wrong console password" 401 "$(code -H 'Content-Type: application/json' --data '{"password":"wrong"}' "$CONSOLE/api/session")"
jar=$(mktemp)
check "console login" 204 "$(code -c "$jar" -H 'Content-Type: application/json' \
  --data "{\"password\":\"$(secret CONSOLE_PASSWORD)\"}" "$CONSOLE/api/session")"
grep -q "ah_console" "$jar" && cookie_flags=$(grep -c "#HttpOnly_" "$jar") || cookie_flags=0
check "session cookie is HttpOnly" 1 "$cookie_flags"
check "API with session" 200 "$(code -b "$jar" "$CONSOLE/api/overview")"
check "session cookie only for $CONSOLE_HOST" "#HttpOnly_$CONSOLE_HOST" "$(grep ah_console "$jar" | awk '{print $1}')"
check "logout" 200 "$(code -b "$jar" -X DELETE "$CONSOLE/api/session")"
rm -f "$jar"
api=$(docker compose ps -q cloud-monitor-api)
check "console API runs as non-root" 10001 "$(docker exec "$api" id -u)"
check "console API has no Docker socket" absent "$(docker exec "$api" test -e /var/run/docker.sock && echo present || echo absent)"
# HTTP status over bash /dev/tcp (the Spring console image has bash, neither node nor curl)
probe='exec 3<>/dev/tcp/docker-proxy/2375 2>/dev/null || { echo unreachable; exit; }; printf "%s %s HTTP/1.0\r\nHost: docker-proxy\r\nContent-Length: 0\r\n\r\n" "$1" "$0" >&3; head -1 <&3 | cut -d" " -f2'
check "proxy refuses container create" 403 "$(docker exec "$api" bash -c "$probe" /containers/create POST)"
check "proxy refuses image listing" 403 "$(docker exec "$api" bash -c "$probe" /images/json GET)"
check "proxy lists project containers" 200 "$(docker exec "$api" bash -c "$probe" /containers/json GET)"
other=$(docker compose ps -q sysmonitor)
check "proxy unreachable from other systems" unreachable \
  "$(docker exec "$other" bash -c '(exec 3<>/dev/tcp/docker-proxy/2375) 2>/dev/null && echo reachable || echo unreachable')"
# J6: the Spring console answers only the host's published port (Docker gateway), loopback and CONSOLE_ALLOWED_CLIENTS;
# another system on the cloud network can open a TCP connection but every request is refused before console processing
console_from_other='exec 3<>/dev/tcp/cloud-monitor-api/8490 2>/dev/null || { echo unreachable; exit; }; printf "%s %s HTTP/1.0\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}" "$1" "$0" >&3; head -1 <&3 | cut -d" " -f2'
check "console health refused to other systems (J6)" 403 "$(docker exec "$other" bash -c "$console_from_other" /health GET)"
check "console login refused to other systems (J6)" 403 "$(docker exec "$other" bash -c "$console_from_other" /api/session POST)"
# positive control: the same probe reaches a system on the shared network (SysMonitor is a JRE image without python3 since 2026-10-16)
check "probe reaches the ServiceRegistry from other systems" reachable \
  "$(docker exec "$other" bash -c '(exec 3<>/dev/tcp/serviceregistry/8443) 2>/dev/null && echo reachable || echo unreachable')"

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

echo "== J1 database credentials and networks"
# Containers without a shell (the native Go and Rust core systems run on scratch images) are probed by a helper container
# that joins their network or PID namespace: a JRE image of this cloud with bash, as the target's own user, read-only,
# without capabilities or privilege gain (J17).
helper_image=$(docker inspect -f '{{.Config.Image}}' "$(docker compose ps -q sysmonitor)")
helper_platform=$(docker image inspect -f '{{.Os}}/{{.Architecture}}' "$helper_image")
has_bash() { docker exec "$1" bash -c true >/dev/null 2>&1; }
in_namespace() {  # in_namespace <container id> network|pid <command>
  user=$(docker inspect -f '{{.Config.User}}' "$1"); network=""
  [ "$2" = pid ] && network="--network none"
  # shellcheck disable=SC2086
  docker run --rm --platform "$helper_platform" --"$2" "container:$1" --user "${user:-0}" --read-only --cap-drop ALL \
    --security-opt no-new-privileges $network --entrypoint bash "$helper_image" -c "$3"
}
probe_from() {  # probe_from <service> <host> <port> -> reachable/unreachable
  id=$(docker compose ps -q "$1"); probe="(exec 3<>/dev/tcp/$2/$3) 2>/dev/null && echo reachable || echo unreachable"
  if has_bash "$id"; then docker exec "$id" bash -c "$probe"; else in_namespace "$id" network "$probe"; fi
}
for db in $(docker compose config --services | grep -- '-db$'); do
  # the root password's key, from the service's db-root-password secret (J7)
  root_key=$(docker compose config --format json | jq -r --arg db "$db" '.services[$db].secrets[]? | select(.target | test("db-root-password$")) | .source' | head -1)
  operators=$(docker compose exec -T -e MYSQL_PWD="$(secret "$root_key")" "$db" mysql -uroot -N \
    -e "SELECT COUNT(*) FROM mysql.user WHERE user='ah-operator'" 2>/dev/null || echo error)
  check "$db: no shared ah-operator user" 0 "$operators"
  prober=sysmonitor; [ "$db" = sysmonitor-db ] && prober=timemanager
  check "$db: unreachable from $prober" unreachable "$(probe_from "$prober" "$db" 3306)"
done
roots=$(grep -E '^AH_DB_ROOT_[A-Z]+=' .env | cut -d= -f2- | sort -u | wc -l | tr -d ' ')
check "every database has its own root password" "$(grep -cE '^AH_DB_ROOT_[A-Z]+=' .env)" "$roots"
# positive control of the probe: DataManager (Java in every deployment of this cloud) reaches its own database. The native
# core systems of the interchangeability overlays keep file state and are on no database network.
check "positive control: DataManager reaches its database" reachable "$(probe_from datamanager datamanager-db 3306)"

echo "== J2 custody of the cloud CA key"
ca_pub=$(openssl pkey -in security/bundles/certificate-authority/ca.key -pubout 2>/dev/null | shasum -a 256 | cut -c1-16)
copies=0
for f in $(find .. \( -name '*.key' -o -name '*.pem' \) -type f -not -path '*/node_modules/*' 2>/dev/null); do
  case "$f" in ../"$(basename "$ROOT_DIR")"/security/ca/ca.key|../"$(basename "$ROOT_DIR")"/security/bundles/certificate-authority/ca.key) continue ;; esac
  [ "$(openssl pkey -in "$f" -pubout 2>/dev/null | shasum -a 256 | cut -c1-16)" = "$ca_pub" ] && { echo "        CA key copy: $f"; copies=$((copies + 1)); }
done
check "no copy of the CA key outside this cloud's CA store" 0 "$copies"

echo "== J15 credential mounts of the running containers"
# Every container, whichever compose files started it (the interchangeability overlays included), mounts only its own
# credential bundle, the CRLs, its database's TLS directory or single public files; never security/x509 or security/ca.
# No mounted directory may hold a CA signing key, except the CertificateAuthority's bundle with the cloud CA key.
ca_hashes=$(for k in "$CA_KEYS"/*.key; do openssl pkey -in "$k" -pubout 2>/dev/null | shasum -a 256 | cut -c1-16; done)
foreign=""; ca_exposed=""
project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$(docker compose ps -q serviceregistry)")
for id in $(docker ps -q --filter "label=com.docker.compose.project=$project"); do
  service=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$id")
  for source in $(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{println .Source}}{{end}}{{end}}' "$id"); do
    case "$source" in "$ROOT_DIR"/security|"$ROOT_DIR"/security/*) ;; *) continue ;; esac
    case "${source#"$ROOT_DIR"/}" in
      security/bundles/?*|security/crl|security/manufacturer-crl|security/x509/db/?*|security/x509/*.crt) ;;
      security/x509/device1-bootstrap.key) ;;  # the demo device's own bootstrap key
      security/primary-stores/?*/*)  # only the system's own stores (the primary folder it is deployed from)
        own=$(docker inspect -f '{{index .Config.Labels "eu.arrowhead.primary-source"}}' "$id")
        store=${source#"$ROOT_DIR"/security/primary-stores/}; store=${store%%/*}
        case "$(basename "$own")" in "ah5-$store-java-spring"|"ah5-$store-java") ;; *) foreign="$foreign $service:${source#"$ROOT_DIR"/}" ;; esac ;;
      *) foreign="$foreign $service:${source#"$ROOT_DIR"/}" ;;
    esac
    [ -d "$source" ] || continue
    for key in $(find "$source" -name '*.key' -type f 2>/dev/null); do
      hash=$(openssl pkey -in "$key" -pubout 2>/dev/null | shasum -a 256 | cut -c1-16)
      printf '%s\n' "$ca_hashes" | grep -qx "$hash" || continue
      [ "$service" = certificate-authority ] && [ "$key" = "$ROOT_DIR/security/bundles/certificate-authority/ca.key" ] && continue
      ca_exposed="$ca_exposed $service:${key#"$ROOT_DIR"/}"
    done
  done
done
check "containers that mount security/x509, security/ca or another foreign credential path" "" "$foreign"
check "CA signing keys reachable in a container other than the CertificateAuthority" "" "$ca_exposed"
stray=$(for name in ca manufacturer-ca onboarding-root-ca onboarding-organization-ca onboarding-local-cloud-ca; do
  if [ -f "$CERT_DIR/$name.key" ]; then printf ' %s' "$name.key"; fi; done)
check "no CA signing key left in security/x509" "" "$stray"
check "CA key store readable by the owner only" 700 "$(stat -f %Lp "$CA_KEYS" 2>/dev/null || stat -c %a "$CA_KEYS")"

echo "== J16 CRL margin"
# The relying parties fail closed on an expired CRL, so the CA must publish with a margin well above its longest
# plausible outage: CRL_VALIDITY_HOURS >= 72, republished hourly; at least 24 h must remain at any time.
epoch() { date -j -u -f '%b %e %T %Y %Z' "$1" +%s 2>/dev/null || date -u -d "$1" +%s; }
next=$(openssl crl -in security/crl/ca.crl -noout -nextupdate | sed 's/^nextUpdate=//')
remaining=$(( ( $(epoch "$next") - $(date -u +%s) ) / 3600 ))
check "CRL signed by the cloud CA" ok "$(openssl crl -in security/crl/ca.crl -noout -CAfile "$CERT_DIR/ca.crt" >/dev/null 2>&1 && echo ok || echo bad)"
check "CRL valid for at least 24 more hours (nextUpdate $next)" yes "$([ "$remaining" -ge 24 ] && echo yes || echo "no, ${remaining} h")"
ca=$(docker compose ps -q certificate-authority)
check "CertificateAuthority is running" running "$(docker inspect -f '{{.State.Status}}' "$ca" 2>/dev/null || echo missing)"
validity=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$ca" 2>/dev/null | sed -n 's/^CRL_VALIDITY_HOURS=//p')
check "CRL_VALIDITY_HOURS of at least 72" yes "$([ "${validity:-0}" -ge 72 ] && echo yes || echo "no, ${validity:-unset}")"

echo "== J3 container hardening"
# every container: non-root (the Docker proxy too since SOS-8: group 0 is enough for the socket), read-only root
# filesystem, all capabilities dropped and none added, no-new-privileges, memory and PID limits; writable host
# mounts only the CertificateAuthority's /crl and the proxy's Docker socket
weak=""; writable=""
for service in $(docker compose ps --services); do
  id=$(docker compose ps -q "$service")
  facts=$(docker inspect -f '{{.Config.User}}|{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.CapDrop}}|{{.HostConfig.CapAdd}}|{{.HostConfig.SecurityOpt}}|{{.HostConfig.Memory}}|{{.HostConfig.PidsLimit}}' "$id")
  user=${facts%%|*}
  # SOS-8 (2026-11-10): no exemption for the Docker proxy any more; it runs as 10001:0 (group 0 opens the socket)
  # root is the uid (before ":"), not the group: 10001:0 is not root
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
for file in secrets/*; do cat "$file"; echo; done > "$values"
in_config=0; in_environ=0; unchecked=0
for id in $(docker compose ps -q); do
  docker inspect "$id" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qFf "$values" && in_config=$((in_config + 1))
  if environ=$(docker exec "$id" cat /proc/1/environ 2>/dev/null) \
      || environ=$(in_namespace "$id" pid 'cat /proc/1/environ' 2>/dev/null); then
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
check "no plaintext console password or shared store password in .env" 0 "$(grep -cE '^(CONSOLE_PASSWORD|X509_STORE_PASSWORD)=' .env || true)"
stores=$(grep -c '^AH_STORE_PW_' .env)
check "one distinct keystore password per system ($stores systems)" "$stores" "$(sed -n 's/^AH_STORE_PW_[A-Z]*=//p' .env | sort -u | wc -l | tr -d ' ')"
opens() { openssl pkcs12 -in "$1" -passin "pass:$2" -noout 2>/dev/null && echo opens || echo refused; }
check "ServiceRegistry keystore opens with its own password" opens \
  "$(opens runtime/ServiceRegistry/config/certificate/ServiceRegistry.p12 "$(secret AH_STORE_PW_SR)")"
check "ServiceRegistry keystore refuses another system's password" refused \
  "$(opens runtime/ServiceRegistry/config/certificate/ServiceRegistry.p12 "$(secret AH_STORE_PW_DSO)")"
check "no .env.previous kept after a verified rotation" absent "$([ -e .env.previous ] && echo present || echo absent)"

echo "== J8 supported component versions"
at_least() { [ -n "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ] && echo "$2" || echo "older than $1: ${2:-unknown}"; }
old_dbs=""
for db in $(docker compose config --services | grep -- '-db$'); do
  version=$(docker compose exec -T "$db" mysqld --version 2>/dev/null | sed -n 's/.*Ver \([0-9.]*\).*/\1/p')
  case "$version" in 8.4.*) ;; *) old_dbs="$old_dbs $db:${version:-?}" ;; esac
done
check "every database runs MySQL 8.4 LTS" "" "$old_dbs"
# LocalCloudManager console and Docker proxy are Spring/Java 21 since 2026-11-09 (formerly Node.js)
java_version() { docker compose exec -T "$1" java -version 2>&1 | sed -n 's/.*version "\([0-9.]*\)".*/\1/p' | head -1 || true; }
java_api=$(java_version cloud-monitor-api)
check "console API on Java 21+ ($java_api)" "$java_api" "$(at_least 21 "$java_api")"
java_proxy=$(java_version docker-proxy)
check "Docker proxy on Java 21+ ($java_proxy)" "$java_proxy" "$(at_least 21 "$java_proxy")"
mosquitto=$(docker compose exec -T mqtt-broker /usr/sbin/mosquitto -h 2>/dev/null | sed -n 's/^mosquitto version \([0-9.]*\).*/\1/p')
check "Mosquitto 2.0.22+ ($mosquitto)" "$mosquitto" "$(at_least 2.0.22 "$mosquitto")"
rabbitmq=$(docker compose exec -T amqp-broker rabbitmqctl -q version 2>/dev/null | tr -d '\r')
check "RabbitMQ 4.1+ ($rabbitmq)" "$rabbitmq" "$(at_least 4.1 "$rabbitmq")"
# (no nginx since 2026-11-09: the Spring LocalCloudManager serves its console itself)

echo "== J5 end-to-end protected inter-cloud sessions"
. "$ROOT_DIR/scripts/registry-auth.sh"
sysop_login
for system in gatetunnel:$(env_value GATETUNNEL_PORT 8453) gatekeeper:$(env_value GATEKEEPER_PORT 8449); do
  name=${system%%:*}
  profile=$(curl -s --max-time 15 $SYSOP_TLS -H "$SYSOP_AUTH" "https://127.0.0.1:${system#*:}/$name/mgmt/status" | jq -r '"\(.relay.profile)/\(.relay.endToEndEncrypted)"')
  check "$name relay profile AH-GT-1 with end-to-end encryption" "ah-gt-1/true" "$profile"
done

echo "== J11 plain-HTTP health ports are container-local"
for target in gatekeeper:8480 gatetunnel:8481 sysmonitor:8482 certificate-authority:8483; do
  check "${target%%:*} health port ${target#*:} unreachable from other systems" unreachable \
    "$(docker exec "$api" bash -c '(exec 3<>"/dev/tcp/$0/$1") 2>/dev/null && echo reachable || echo unreachable' "${target%%:*}" "${target#*:}")"
done

echo "== J18 token-free health over mutual TLS discloses liveness only"
# any certificate of the cloud, no token: /health answers with status and system name, without the relay, session,
# broker or registration detail that /<system>/mgmt/status gives to LocalCloudManager and Sysop
for port in $(env_value GATEKEEPER_PORT 8449) $(env_value GATETUNNEL_PORT 8453) $(env_value SYSMONITOR_PORT 8475) $(env_value CERTIFICATE_AUTHORITY_PORT 8448); do
  keys=$(curl -s --max-time 10 --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/smoke-client.crt" --key "$CERT_DIR/smoke-client.key" \
    "https://127.0.0.1:$port/health" | jq -r 'keys | join(",")' 2>/dev/null || echo unreadable)
  # the native runtime answered status and system; the Spring CertificateAuthority, GateTunnel and SysMonitor (2026-11-09)
  # refuse a token-free request with a bare 401 (errorCode, errorMessage, exceptionType), which discloses even less
  case "$keys" in errorCode,errorMessage,exceptionType) keys="status,system (refused: 401)" ;; status,system) keys="status,system (refused: 401)" ;; esac
  check "/health at port $port without a token discloses liveness at most" "status,system (refused: 401)" "$keys"
done

echo "== J19 identity passwords: one per container, no operator seeds"
# every container mounts at most its own identity password; the Sysop and SmokeClient passwords and the seed directory
# of bootstrap-authentication.sh are in no container; no plaintext copies outside .env and secrets/
shared=""; seeds=""
for id in $(docker ps -q --filter "label=com.docker.compose.project=$project"); do
  service=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$id")
  sources=$(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{println .Source}}{{end}}{{end}}' "$id")
  passwords=$(printf '%s\n' "$sources" | grep -c '/secrets/AH_PW_' || true)
  [ "$passwords" -le 1 ] || shared="$shared $service($passwords)"
  printf '%s\n' "$sources" | grep -qE '/secrets/bootstrap/|/runtime-secrets/|/secrets/(ARROWHEAD_SYSOP_PASSWORD|AH_PW_SMK)$' && seeds="$seeds $service"
done
check "containers with more than one identity password" "" "$shared"
check "containers with the Sysop or SmokeClient password or a bootstrap seed" "" "$seeds"
check "no seed directory left (secrets/bootstrap, interchangeability/runtime-secrets)" absent \
  "$([ -e secrets/bootstrap ] || [ -e interchangeability/runtime-secrets ] && echo present || echo absent)"

echo "== J23 only Sysop is a sysop"
# a sysop identity passes every management filter and sysop-only API, so the console identity (LocalCloudManager) and
# every other system must rely on explicit grants; read through Authentication management as Sysop, no system login
identities=$(curl -s --max-time 15 $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' \
  --data '{"pagination":{"page":0,"size":1000}}' "$AUTH_URL/authentication/mgmt/identities/query")
check "identities that are sysops" "Sysop" \
  "$(printf '%s' "$identities" | jq -r '[(.identities // .entries // [])[] | select(.sysop == true) | .systemName] | sort | join(",")' 2>/dev/null || echo unreadable)"
check "LocalCloudManager identity exists and is not a sysop" false \
  "$(printf '%s' "$identities" | jq -r '[(.identities // .entries // [])[] | select(.systemName == "LocalCloudManager") | .sysop | tostring] | first // "missing"' 2>/dev/null || echo unreadable)"

echo "== LC view: localCloudConfiguration is granted to the console only"
# the console's LC view orchestrates LocalCloudConfigurator's localCloudConfiguration, and the configurator verifies every
# call with ConsumerAuthorization (configure-localcloudconfigurator-policy.sh, VERIFIERS); read as Sysop, no system login
lcc_check() {  # lcc_check <consumer> <target> <scope>... -> number of granted scopes
  provider=LocalCloudConfigurator; [ "$2" = authorization ] && provider=ConsumerAuthorization
  consumer=$1; target=$2; shift 2
  list=$(for scope in "$@"; do printf '{"provider":"%s","consumer":"%s","cloud":"LOCAL","targetType":"SERVICE_DEF","target":"%s","scope":"%s"}\n' \
    "$provider" "$consumer" "$target" "$scope"; done | jq -cs '{list: .}')
  curl -s --max-time 15 $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' --data "$list" \
    "https://127.0.0.1:$(env_value CONSUMER_AUTHORIZATION_PORT 8445)/consumerauthorization/authorization/mgmt/check" |
    jq -r '[.entries[]? | select(.granted == true)] | length' 2>/dev/null || echo unreadable
}
LCC_OPERATIONS="catalog status list-configurations get-configuration create-configuration update-configuration remove-configuration plan submit-deployment get-deployment"
# shellcheck disable=SC2086
check "LocalCloudManager granted the 10 localCloudConfiguration operations" 10 "$(lcc_check LocalCloudManager localCloudConfiguration $LCC_OPERATIONS)"
check "LocalCloudConfigurator may verify its consumers" 1 "$(lcc_check LocalCloudConfigurator authorization verify)"
# shellcheck disable=SC2086
check "another system (SmokeClient) granted no localCloudConfiguration operation" 0 "$(lcc_check SmokeClient localCloudConfiguration $LCC_OPERATIONS)"

echo "== SoLC view: soLocalCloudConfiguration is granted to the console only; SoLocalCloudConfigurator reads designs only"
# 2026-11-11: the console's SoLC view orchestrates SoLocalCloudConfigurator, which verifies every call; SoLocalCloudConfigurator
# reads LocalCloudConfigurator's stored designs and may not change them or deploy (configure-*localcloudconfigurator-policy.sh)
grant_check() {  # grant_check <provider> <consumer> <target> <scope>... -> number of granted scopes
  provider=$1; consumer=$2; target=$3; shift 3
  list=$(for scope in "$@"; do printf '{"provider":"%s","consumer":"%s","cloud":"LOCAL","targetType":"SERVICE_DEF","target":"%s","scope":"%s"}\n' \
    "$provider" "$consumer" "$target" "$scope"; done | jq -cs '{list: .}')
  curl -s --max-time 15 $SYSOP_TLS -H "$SYSOP_AUTH" -H 'Content-Type: application/json' --data "$list" \
    "https://127.0.0.1:$(env_value CONSUMER_AUTHORIZATION_PORT 8445)/consumerauthorization/authorization/mgmt/check" |
    jq -r '[.entries[]? | select(.granted == true)] | length' 2>/dev/null || echo unreadable
}
if docker compose ps -q solocalcloudconfigurator 2>/dev/null | grep -q .; then
  SOLC_OPERATIONS="catalog list-lc-designs list-designs get-design create-design update-design remove-design plan build-package list-packages get-package remove-package"
  # shellcheck disable=SC2086
  check "LocalCloudManager granted the 12 soLocalCloudConfiguration operations" 12 "$(grant_check SoLocalCloudConfigurator LocalCloudManager soLocalCloudConfiguration $SOLC_OPERATIONS)"
  # shellcheck disable=SC2086
  check "another system (SmokeClient) granted no soLocalCloudConfiguration operation" 0 "$(grant_check SoLocalCloudConfigurator SmokeClient soLocalCloudConfiguration $SOLC_OPERATIONS)"
  check "SoLocalCloudConfigurator may verify its consumers" 1 "$(grant_check ConsumerAuthorization SoLocalCloudConfigurator authorization verify)"
  check "SoLocalCloudConfigurator reads stored local-cloud designs (catalog, list, get)" 3 \
    "$(grant_check LocalCloudConfigurator SoLocalCloudConfigurator localCloudConfiguration catalog list-configurations get-configuration)"
  check "SoLocalCloudConfigurator may not change a design, plan or deploy" 0 \
    "$(grant_check LocalCloudConfigurator SoLocalCloudConfigurator localCloudConfiguration create-configuration update-configuration remove-configuration plan submit-deployment)"
  check "SoLocalCloudConfigurator has no Docker socket" 0 \
    "$(docker inspect --format '{{range .Mounts}}{{.Source}} {{end}}' "$(docker compose ps -q solocalcloudconfigurator)" | tr ' ' '\n' | grep -c 'docker.sock' || true)"
else
  echo "  skip SoLocalCloudConfigurator is not deployed"
fi

echo "== J12 Blacklist enforcement"
# SmokeClient is blacklisted for the test only; the entry is removed again even when the test stops early
blacklist_call() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 $SYSOP_TLS -H "$SYSOP_AUTH" "$@"; }
BLACKLIST_URL="https://127.0.0.1:$(env_value BLACKLIST_PORT 8464)/blacklist/mgmt"
trap 'blacklist_call -X DELETE "$BLACKLIST_URL/remove?names=SmokeClient" >/dev/null' EXIT
smoke_echo_token=$(curl -fsS --max-time 15 --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/smoke-client.crt" --key "$CERT_DIR/smoke-client.key" \
  -H 'Content-Type: application/json' --data "{\"systemName\":\"SmokeClient\",\"credentials\":{\"password\":\"$(secret AH_PW_SMK)\"}}" \
  "$AUTH_URL/authentication/identity/login" | jq -r '.token')
smoke_echo() { code --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/smoke-client.crt" --key "$CERT_DIR/smoke-client.key" \
  -H "Authorization: Bearer IDENTITY-TOKEN//$smoke_echo_token" "https://127.0.0.1:$1"; }
# <port>/<path> of each filtered system. Served means answered after the Blacklist filter, which refuses (403) before
# any routing: 200, or 404 where the system has no echo (the Java orchestrators; the Go core has one).
FILTERED="$(env_value SERVICEREGISTRY_PORT 8443)/serviceregistry/monitor/echo $(env_value CONSUMER_AUTHORIZATION_PORT 8445)/consumerauthorization/monitor/echo
$(env_value DYNAMIC_ORCHESTRATION_PORT 8441)/serviceorchestration/monitor/echo $(env_value SIMPLE_ORCHESTRATION_PORT 8442)/serviceorchestration/monitor/echo
$(env_value TRANSLATION_MANAGER_PORT 8465)/translation/monitor/echo $(env_value DEVICE_QOS_EVALUATOR_PORT 8472)/deviceqosevaluator/monitor/echo"
served() { case "$1" in 200|404) echo served ;; *) echo "$1" ;; esac; }
check "blacklist SmokeClient" 201 "$(blacklist_call -H 'Content-Type: application/json' \
  --data '{"entities":[{"systemName":"SmokeClient","reason":"smoke-security J12"}]}' "$BLACKLIST_URL/create")"
for target in $FILTERED; do check "blacklisted SmokeClient refused at port ${target%%/*}" 403 "$(smoke_echo "$target")"; done
check "remove SmokeClient from the blacklist" 200 "$(blacklist_call -X DELETE "$BLACKLIST_URL/remove?names=SmokeClient")"
for target in $FILTERED; do check "SmokeClient served again at port ${target%%/*}" served "$(served "$(smoke_echo "$target")")"; done
trap - EXIT

echo "== J9 reserved service definitions"
smoke_token=$(curl -fsS --max-time 15 --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/smoke-client.crt" --key "$CERT_DIR/smoke-client.key" \
  -H 'Content-Type: application/json' --data "{\"systemName\":\"SmokeClient\",\"credentials\":{\"password\":\"$(secret AH_PW_SMK)\"}}" \
  "$AUTH_URL/authentication/identity/login" | jq -r '.token')
for definition in certificateSigning identity serviceDiscovery; do
  # the payload is built outside "$(...)": /bin/sh (bash 3.2) mis-parses escaped quotes inside it
  payload=$(jq -cn --arg d "$definition" '{serviceDefinitionName: $d, version: "1.0.0", interfaces: [{templateName: "generic_https",
    protocol: "https", policy: "CERT_AUTH", properties: {accessAddresses: ["probe.example"], accessPort: 443, basePath: "/probe",
    operations: {op: {method: "POST", path: "/op"}}}}]}')
  check "SmokeClient cannot register $definition" 403 "$(code --cacert "$CERT_DIR/ca.crt" --cert "$CERT_DIR/smoke-client.crt" \
    --key "$CERT_DIR/smoke-client.key" -H "Authorization: Bearer IDENTITY-TOKEN//$smoke_token" -H 'Content-Type: application/json' \
    --data "$payload" "https://127.0.0.1:$(env_value SERVICEREGISTRY_PORT 8443)/serviceregistry/service-discovery/register")"
done

echo "== J10 Erlang distribution of the AMQP broker"
for port in 4369 25672; do
  check "AMQP broker port $port unreachable from other systems" unreachable \
    "$(docker exec "$other" bash -c "(exec 3<>/dev/tcp/amqp-broker/$port) 2>/dev/null && echo reachable || echo unreachable")"
done
check "positive control: AMQPS 5671 reachable" reachable \
  "$(docker exec "$other" bash -c '(exec 3<>/dev/tcp/amqp-broker/5671) 2>/dev/null && echo reachable || echo unreachable')"

echo "== J13 host key hygiene"
check "no stray upstream sample keystores (runtime/*/config/certificte)" 0 "$(find runtime -type d -name certificte | wc -l | tr -d ' ')"
check "no private key or keystore readable by group or others" 0 \
  "$(find security runtime secrets \( -name '*.key' -o -name '*.p12' \) -perm +044 2>/dev/null | wc -l | tr -d ' ')"
check "no .env.previous with an earlier secret set" absent "$( [ -e .env.previous ] && echo present || echo absent)"
# J20/SOS-10 (2026-11-10): every private key in security/x509 belongs to a system of this cloud's compose file, the CA
# (ca.key, J2) or a database server key (db/); a key nothing deploys (as authentication-registry-mtls and
# registry-bootstrap-proxy were) is reported. Service and system names are compared without "-" and case.
services=$(docker compose config --services 2>/dev/null | tr -d '-' | tr 'A-Z' 'a-z')
stray=""
for key in security/x509/*.key; do
  [ -e "$key" ] || continue
  name=$(basename "$key" .key)
  # not services: the CA (J2), relay identities, the operator and test identities, the console's identities (served by
  # cloud-monitor-api), and Device1's manufacturer-issued bootstrap key used by the onboarding checks
  case "$name" in ca|*-relay|org-ca|sysop|smoke-client|local-cloud-manager|local-cloud-manager-spring|device1-bootstrap) continue ;; esac
  printf '%s\n' "$services" | grep -qx "$(printf '%s' "$name" | tr -d '-' | tr 'A-Z' 'a-z')" || stray="$stray $name"
done
check "no key in security/x509 that no service of this cloud deploys" "" "$(echo $stray)"

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
HTTPS_PORTS="8443 8441 8442 8445 8444 8464 8465 8472 8435 8461 8467 8463 8455 8432 8459 8457 8475 8449 8453 8478 8448"
work=$(mktemp -d)
openssl req -new -newkey rsa:2048 -nodes -keyout "$work/probe.key" -out "$work/probe.csr" \
  -subj "/C=SE/O=Company/OU=$CLOUD/CN=RevocationProbe.$CLOUD.Company.arrowhead.eu/dnQualifier=sy" 2>/dev/null
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n' > "$work/probe.ext"
openssl x509 -req -in "$work/probe.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CA_KEYS/ca.key" -CAserial "$work/probe.srl" \
  -CAcreateserial -days 1 -extfile "$work/probe.ext" -out "$work/probe.crt" 2>/dev/null
# the relay checks need the organisation cross-certificate of a federated cloud; a cloud without federation (no
# security/x509/ca-cross.crt, e.g. the v5.3.0 cloud) skips them
federated=no; [ -f "$CERT_DIR/ca-cross.crt" ] && federated=yes
[ "$federated" = yes ] && cat "$work/probe.crt" "$CERT_DIR/ca-cross.crt" > "$work/probe-chain.crt"
handshake() {  # handshake <port> <ca file> <chain> -> accepted | refused
  out=$(openssl s_client -connect "127.0.0.1:$1" -tls1_2 -CAfile "$2" -cert "$3" -cert_chain "$3" -key "$work/probe.key" \
    </dev/null 2>&1 || true)
  if printf '%s' "$out" | grep -q "alert"; then echo refused
  elif printf '%s' "$out" | grep -q "Verify return code: 0"; then echo accepted
  else echo error; fi
}
https_probe() {  # https_probe <port> [<cert> <key>] -> accepted (any HTTP answer, e.g. 401 without a token) | refused (no HTTP answer)
  # Tomcat refuses with a TLS alert, the JDK HTTPS server of the Java support runtime by closing the connection
  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$CERT_DIR/ca.crt" --cert "${2:-$work/probe.crt}" \
    --key "${3:-$work/probe.key}" "https://127.0.0.1:$1/" || true)
  if [ "$status" = 000 ]; then echo refused; else echo accepted; fi
}
check "MQTT broker accepts the probe" accepted "$(handshake "$MQTT_PORT" "$CERT_DIR/ca.crt" "$work/probe.crt")"
check "AMQP broker accepts the probe" accepted "$(handshake "$AMQP_PORT" "$CERT_DIR/ca.crt" "$work/probe.crt")"
if [ "$federated" = yes ]; then check "relay accepts the probe" accepted "$(handshake "$RELAY_PORT" "$CERT_DIR/org-ca.crt" "$work/probe-chain.crt")"
else echo "  skip  relay checks: no inter-cloud federation (no ca-cross.crt)"; fi
for port in $HTTPS_PORTS; do check "HTTPS $port accepts the probe" accepted "$(https_probe "$port")"; done
./scripts/revoke-certificate.sh "$work/probe.crt" | sed 's/^/  /'
sleep 12  # crl-watch.sh polls every 10 s
check "MQTT broker refuses the revoked probe" refused "$(handshake "$MQTT_PORT" "$CERT_DIR/ca.crt" "$work/probe.crt")"
check "AMQP broker refuses the revoked probe" refused "$(handshake "$AMQP_PORT" "$CERT_DIR/ca.crt" "$work/probe.crt")"
[ "$federated" = yes ] && check "relay refuses the revoked probe" refused "$(handshake "$RELAY_PORT" "$CERT_DIR/org-ca.crt" "$work/probe-chain.crt")"
# the Spring systems re-read the CRL every 30 s (arrowhead.ssl.crl-poll-seconds), the Java support runtime on each handshake
for port in $HTTPS_PORTS; do
  waited=0
  while [ "$(https_probe "$port")" != refused ] && [ "$waited" -lt 60 ]; do sleep 5; waited=$((waited + 5)); done
  check "HTTPS $port refuses the revoked probe" refused "$(https_probe "$port")"
done
# Onboarding also trusts the manufacturer CA of the bootstrap certificates and checks them against the manufacturer's CRL
# (scripts/manufacturer-crl.sh), fail closed as well; no other system trusts that CA
openssl req -new -newkey rsa:2048 -nodes -keyout "$work/bootstrap.key" -out "$work/bootstrap.csr" \
  -subj "/C=SE/O=Test Manufacturer/CN=RevocationProbeDevice" 2>/dev/null
openssl x509 -req -in "$work/bootstrap.csr" -CA "$CERT_DIR/manufacturer-ca.crt" -CAkey "$CA_KEYS/manufacturer-ca.key" \
  -CAserial "$work/bootstrap.srl" -CAcreateserial -days 1 -extfile "$work/probe.ext" -out "$work/bootstrap.crt" 2>/dev/null
check "Onboarding accepts a manufacturer-issued probe" accepted "$(https_probe 8435 "$work/bootstrap.crt" "$work/bootstrap.key")"
check "ServiceRegistry refuses a manufacturer-issued probe" refused "$(https_probe 8443 "$work/bootstrap.crt" "$work/bootstrap.key")"
./scripts/manufacturer-crl.sh --revoke "$work/bootstrap.crt" | sed 's/^/  /'
waited=0
while [ "$(https_probe 8435 "$work/bootstrap.crt" "$work/bootstrap.key")" != refused ] && [ "$waited" -lt 60 ]; do sleep 5; waited=$((waited + 5)); done
check "Onboarding refuses the revoked manufacturer-issued probe" refused "$(https_probe 8435 "$work/bootstrap.crt" "$work/bootstrap.key")"
check "Onboarding still accepts Device1's bootstrap certificate" accepted \
  "$(https_probe 8435 "$CERT_DIR/device1-bootstrap.crt" "$CERT_DIR/device1-bootstrap.key")"
rm -f "$work/bootstrap.key" "$work/bootstrap.csr" "$work/bootstrap.srl" "$work/bootstrap.crt"
rm -f "$work/probe.key" "$work/probe.csr" "$work/probe.ext" "$work/probe.srl" "$work/probe.crt" "$work/probe-chain.crt"
rmdir "$work"

if [ "$failures" -eq 0 ]; then echo "Security regression test passed"; else echo "Security regression test: $failures failure(s)"; exit 1; fi
