#!/bin/sh
# Generates the runtime of the native Go core and support systems (2026-10-17):
#   security/bundles-go/<service>/  ca.crt, <stem>.crt, <stem>.key, password (+ role extras), directory 0700, files 0600
#   runtime-go/<service>.json       JSON configuration (no secrets; file references below /certs and /state)
# The Go systems refuse secret and key files that are group/world readable; Docker Desktop keeps the 0600 modes of
# these bind-mounted files for the container's root user (the services drop all capabilities). Idempotent.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib-secrets.sh
X509=security/x509
BUNDLES=security/bundles-go
RUNTIME=runtime-go
SUFFIX=GoCloud.Company.arrowhead.eu
umask 077
mkdir -p "$BUNDLES" "$RUNTIME"
chmod 700 "$BUNDLES"

# service|system|certificate stem|password key|container port|kind
SYSTEMS="authentication|Authentication|authentication|AH_PW_AUTH|8444|core
consumerauthorization|ConsumerAuthorization|consumerauthorization|AH_PW_CA|8445|core
serviceorchestration-dynamic|DynamicServiceOrchestration|serviceorchestration-dynamic|AH_PW_DSO|8441|core
serviceorchestration-simple|SimpleStoreServiceOrchestration|serviceorchestration-simple|AH_PW_SSO|8442|core
blacklist|Blacklist|blacklist|AH_PW_BL|8464|support
translation-manager|TranslationManager|translation-manager|AH_PW_TM|8465|support
test-translation|TestTranslation|test-translation|AH_PW_TT|8466|support
device-qos-evaluator|DeviceQoSEvaluator|device-qos-evaluator|AH_PW_DQE|8472|support
onboarding|Onboarding|onboarding|AH_PW_ONB|8435|support
datamanager|DataManager|datamanager|AH_PW_DM|8461|support
timemanager|TimeManager|timemanager|AH_PW_TMG|8463|support
eventhandler|EventHandler|eventhandler|AH_PW_EH|8455|support
plantdescriptionengine|PlantDescriptionEngine|plantdescriptionengine|AH_PW_PDE|8432|support
configuration|Configuration|configuration|AH_PW_CFG|8459|support
choreographer|Choreographer|choreographer|AH_PW_CHO|8457|support
sysmonitor|SysMonitor|sysmonitor|AH_PW_SM|8475|support
gatekeeper|Gatekeeper|gatekeeper|AH_PW_GK|8449|support
gatetunnel|GateTunnel|gatetunnel|AH_PW_GT|8453|support
aigym|AIGym|aigym|AH_PW_AIG|8478|support
certificate-authority|CertificateAuthority|certificate-authority|AH_PW_CAU|8448|support"

put() {  # source destination
  cp "$1" "$2"
  chmod 600 "$2"
}
put_secret() {  # key destination
  printf '%s\n' "$(secret "$1")" > "$2"
  chmod 600 "$2"
}

# Management whitelists, carried over from the Java configuration (MANAGEMENT_WHITELIST / sysop-only). The Go core has
# administrative clients are listed here; PDE has a separate exception limited to the DSO plant API.
whitelist() {
  case $1 in
    Authentication) echo '["Onboarding"]' ;;
    # J6: not the console identity LocalCloudManager (the policy scripts act as Sysop)
    ConsumerAuthorization) echo '["DynamicServiceOrchestration","SimpleStoreServiceOrchestration","Gatekeeper","Onboarding"]' ;;
    DynamicServiceOrchestration) echo '["LocalCloudManager"]' ;;
    SimpleStoreServiceOrchestration) echo '["LocalCloudManager"]' ;;
    PlantDescriptionEngine|Gatekeeper|GateTunnel|SysMonitor) echo '["LocalCloudManager"]' ;;
    *) echo '[]' ;;
  esac
}

# Support-system extras: upstreams (explicit HTTPS origins, certificate pinned), telemetry, federation, CA key
support_extras() {
  case $1 in
    SysMonitor) echo '"upstreams":{"ServiceOrchestration":"https://serviceorchestration-dynamic:8441"},"upstreamSystems":{"ServiceOrchestration":"DynamicServiceOrchestration"},"mqttURL":"ssl://mqtt-broker:8883","defaultSubscription":"all",' ;;
    Choreographer) echo '"upstreams":{"ServiceOrchestration":"https://serviceorchestration-dynamic:8441"},"upstreamSystems":{"ServiceOrchestration":"DynamicServiceOrchestration"},' ;;
    # AIGym orchestrates sysMonitorData (MQTT) for its experiments
    AIGym) echo '"upstreams":{"ServiceOrchestration":"https://serviceorchestration-dynamic:8441"},"upstreamSystems":{"ServiceOrchestration":"DynamicServiceOrchestration"},' ;;
    # device discovery and RTT/augmented load measurement (Java measurement engine)
    DeviceQoSEvaluator) echo '"qosMeasurement":true,' ;;
    Onboarding) echo '"upstreams":{"CertificateAuthority":"https://certificate-authority:8448"},"clientCA":"/certs/manufacturer-ca.crt",' ;;
    # SysMonitor history for alarms; DSO owns the atomic active-plant rule snapshot
    PlantDescriptionEngine) echo '"upstreams":{"SysMonitor":"https://sysmonitor:8475","DynamicServiceOrchestration":"https://serviceorchestration-dynamic:8441"},' ;;
    # v5.3.0: no federation (no relay, neighbours or organisation PKI), as the Java v5.3.0 cloud
    Gatekeeper) echo '"upstreams":{"GateTunnel":"https://gatetunnel:8453"},"federationEnabled":false,' ;;
    GateTunnel) echo '"federationEnabled":false,' ;;
    # test interface/data model translator: reports bridge usage to the TranslationManager
    # MQTT bridges (2026-10-24): HTTPS -> MQTT targets and MQTT consumers on the local broker
    TestTranslation) echo '"upstreams":{"TranslationManager":"https://translation-manager:8465"},"mqttURL":"ssl://mqtt-broker:8883",' ;;
    CertificateAuthority) echo '"caCertificate":"/certs/ca.crt","caSigningKey":"/certs/ca.key","crlExportFile":"/crl/ca.crl",' ;;
    *) echo '' ;;
  esac
}

count=0
printf '%s\n' "$SYSTEMS" | while IFS='|' read -r service system stem pwkey port kind; do
  dir="$BUNDLES/$service"
  mkdir -p "$dir"
  chmod 700 "$dir"
  put "$X509/ca.crt" "$dir/ca.crt"
  put "$X509/$stem.crt" "$dir/$stem.crt"
  put "$X509/$stem.key" "$dir/$stem.key"
  put_secret "$pwkey" "$dir/password"
  extra=""
  case $system in
    Authentication) put_secret ARROWHEAD_SYSOP_PASSWORD "$dir/bootstrap-password"
      extra='"bootstrapName":"Sysop","bootstrapPasswordFile":"/certs/bootstrap-password",' ;;
    ConsumerAuthorization) put_secret AH_GO_TOKEN_SECRET "$dir/token-secret"
      extra='"tokenSecretFile":"/certs/token-secret",' ;;
    # inter-cloud orchestration (ALLOW_INTERCLOUD/ONLY_INTERCLOUD) through the local Gatekeeper
    DynamicServiceOrchestration) extra='"gatekeeperURL":"https://gatekeeper:8449",' ;;
    CertificateAuthority) put "$X509/ca.key" "$dir/ca.key" ;;
    # device manufacturers whose bootstrap certificates the operator can approve (client certificates only)
    Onboarding) put "$X509/manufacturer-ca.crt" "$dir/manufacturer-ca.crt" ;;
    Gatekeeper|GateTunnel)
      for f in org-ca.crt "$stem-relay.key" "$stem-relay-chain.crt"; do [ -f "$X509/$f" ] && put "$X509/$f" "$dir/$f"; done ;;
  esac
  # Revocation (J4): every Go system checks peers of the cloud CA against its CRL (fail closed)
  extra="$extra\"crlFile\":\"/crl/ca.crl\","
  # Blacklist enforcement (J12), as in TestCloud: the core systems are not checked, so bootstrap does not depend on it
  case $system in
    ConsumerAuthorization|DynamicServiceOrchestration|SimpleStoreServiceOrchestration|TranslationManager|DeviceQoSEvaluator)
      extra="$extra\"blacklistURL\":\"https://blacklist:8464\",\"blacklistExclude\":[\"ServiceRegistry\",\"Authentication\",\"ConsumerAuthorization\",\"DynamicServiceOrchestration\",\"SimpleStoreServiceOrchestration\",\"CertificateAuthority\"]," ;;
  esac
  if [ "$kind" = support ]; then
    extra="$extra$(support_extras "$system")\"monitorEnabled\":true,\"amqpURL\":\"amqps://amqp-broker:5671\",\"authorizationPolicy\":\"enforce\","
  else
    # native sysMonitor telemetry of the core systems (2026-10-17)
    extra="$extra\"monitorEnabled\":true,\"amqpURL\":\"amqps://amqp-broker:5671\","
    # MQTT API (2026-10-24, Java mqtt.api.enabled); SimpleStore shares the broker with DSO, so it has its own prefix
    extra="$extra\"mqttURL\":\"ssl://mqtt-broker:8883\","
    [ "$system" = SimpleStoreServiceOrchestration ] && extra="$extra\"mqttTopicPrefix\":\"arrowhead/serviceorchestration-simple\","
  fi
  cat > "$RUNTIME/$service.json" <<EOF
{
  "name": "$system",
  "listen": ":$port",
  "cloudSuffix": "$SUFFIX",
  "certificate": "/certs/$stem.crt",
  "privateKey": "/certs/$stem.key",
  "ca": "/certs/ca.crt",
  "state": "/state/$service.json",
  "passwordFile": "/certs/password",
  $extra
  "authenticationURL": "https://authentication:8444",
  "serviceRegistryURL": "https://serviceregistry:8443",
  "authorizationURL": "https://consumerauthorization:8445",
  "managementWhitelist": $(whitelist "$system"),
  "managementPolicy": "authorization",
  "register": true,
  "advertiseAddress": "$service",
  "advertisePort": $port
}
EOF
  # validate and pretty-print (fails on a malformed template)
  jq . "$RUNTIME/$service.json" > "$RUNTIME/$service.json.tmp" && mv "$RUNTIME/$service.json.tmp" "$RUNTIME/$service.json"
  chmod 644 "$RUNTIME/$service.json"
done
echo "Go runtime: $(ls "$RUNTIME" | wc -l | tr -d ' ') configurations in $RUNTIME, bundles in $BUNDLES"
