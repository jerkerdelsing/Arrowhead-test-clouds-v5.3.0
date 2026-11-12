#!/usr/bin/env python3
"""One-off migration of compose.yaml to the native Go core and support systems (2026-10-17).

Replaces the service blocks of the 19 Go-ported systems with services of the image arrowhead-go-native, puts their
former MySQL services into the inactive profile java-legacy (volumes kept, never removed) and declares the new state
volumes go-<service>-state. Text-level, so comments and anchors of the other services stay untouched.
The original file is in upgrade-backups/go-full-20261017/compose.yaml.
"""
import re
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "compose.yaml"
TAG = "arrowhead-go-native:5.2.2-20261017"
SR_TAG = "arrowhead-serviceregistry-go:5.2.2-20261017"

# service -> (executable, container port)
SYSTEMS = {
    "authentication": ("authentication", 8444),
    "consumerauthorization": ("consumer-authorization", 8445),
    "serviceorchestration-dynamic": ("serviceorchestration-dynamic", 8441),
    "serviceorchestration-simple": ("serviceorchestration-simple", 8442),
    "blacklist": ("Blacklist", 8464),
    "translation-manager": ("TranslationManager", 8465),
    "device-qos-evaluator": ("DeviceQoSEvaluator", 8472),
    "onboarding": ("Onboarding", 8435),
    "datamanager": ("DataManager", 8461),
    "timemanager": ("TimeManager", 8463),
    "eventhandler": ("EventHandler", 8455),
    "plantdescriptionengine": ("PlantDescriptionEngine", 8432),
    "configuration": ("Configuration", 8459),
    "choreographer": ("Choreographer", 8457),
    "sysmonitor": ("SysMonitor", 8475),
    "gatekeeper": ("Gatekeeper", 8449),
    "gatetunnel": ("GateTunnel", 8453),
    "aigym": ("AIGym", 8478),
    "certificate-authority": ("CertificateAuthority", 8448),
}
# environment of the imported legacy-mTLS relay engine (internal/relay), unchanged from the former native Go services
RELAY_ENV = {
    "gatekeeper": {"FEDERATION_PROFILE": "legacy-mtls", "RELAY_HOST": "arrowhead-relay", "RELAY_PORT": "8883",
                   "CONSUMER_AUTHORIZATION_URL": "https://consumerauthorization:8445",
                   "GATETUNNEL_URL": "https://gatetunnel:8453"},
    "gatetunnel": {"FEDERATION_PROFILE": "legacy-mtls", "RELAY_HOST": "arrowhead-relay", "RELAY_PORT": "8883",
                   "ADVERTISED_ADDRESS": "gatetunnel", "MIN_TUNNEL_PORT": "8000", "MAX_TUNNEL_PORT": "8099",
                   "NEIGHBOR_CLOUDS": "TestCloud"},
}
# start order: Authentication needs only the registry; everyone else waits for Authentication's listener
DEPENDS = {"authentication": ["serviceregistry"]}
DEFAULT_DEPENDS = ["serviceregistry", "authentication"]

ANCHOR = f"""x-go-system: &go-system
  # Native Go core/support systems (../ah5-core-go, ../ah5-support-go), 2026-10-17. JSON configuration in
  # runtime-go/<service>.json, credentials in security/bundles-go/<service> (scripts/make-go-runtime.sh),
  # private JSON state on the named volume go-<service>-state. Root user only to read the owner-only (0600)
  # bundle files; all capabilities dropped, read-only root filesystem.
  image: {TAG}
  build:
    context: ./go-native-full
    dockerfile: Dockerfile.prebuilt
  platform: ${{DOCKER_PLATFORM:-linux/amd64}}
  restart: unless-stopped
  networks: [arrowhead]
  user: "0:0"
  read_only: true
  cap_drop: [ALL]
  security_opt: [no-new-privileges:true]
  pids_limit: 128
  mem_limit: 192m

"""

lines = open(PATH).read().split("\n")
service_re = re.compile(r"^  ([a-z0-9-]+):\s*$")

# split into blocks by top-level service lines inside "services:"; keep preceding comment lines with the next block
out, i = [], 0
in_services = False
replaced, profiled = set(), set()
ports_of = {}
while i < len(lines):
    line = lines[i]
    if line == "services:":
        in_services = True
        out.append(line)
        i += 1
        continue
    if in_services and re.match(r"^[a-z]", line):
        in_services = False
    m = service_re.match(line) if in_services else None
    if not m:
        out.append(line)
        i += 1
        continue
    name = m.group(1)
    j = i + 1
    while j < len(lines) and not service_re.match(lines[j]) and not re.match(r"^[a-z]", lines[j]):
        j += 1
    # trailing comments/blank lines belong to the next block
    k = j
    while k > i + 1 and (lines[k - 1].strip() == "" or lines[k - 1].startswith("  #")):
        k -= 1
    block, tail = lines[i:k], lines[k:j]
    if name in SYSTEMS:
        exe, port = SYSTEMS[name]
        ports = []
        for n, l in enumerate(block):
            if l == "    ports:":
                for p in block[n + 1:]:
                    if p.startswith("      - "):
                        ports.append(p)
                    else:
                        break
        new = [f"  {name}:", "    <<: *go-system",
               f'    entrypoint: ["/usr/local/bin/{exe}", "-config", "/config/config.json"]', "    depends_on:"]
        for d in DEPENDS.get(name, DEFAULT_DEPENDS):
            new += [f"      {d}:", "        condition: service_started"]
        if name in RELAY_ENV:
            new.append("    environment:")
            new += [f"      {k}: {v}" for k, v in RELAY_ENV[name].items()]
        new += ["    volumes:", f"      - ./runtime-go/{name}.json:/config/config.json:ro",
                f"      - ./security/bundles-go/{name}:/certs:ro", f"      - go-{name}-state:/state"]
        if name == "certificate-authority":
            new += ["      # published CRL (crlExportFile), read by the brokers and the relay", "      - ./security/crl:/crl"]
        if ports:
            new += ["    ports:"] + ports
        new += ["    healthcheck:", f'      test: ["CMD", "/usr/local/bin/ah-probe", "127.0.0.1:{port}"]',
                "      interval: 30s", "      timeout: 4s", "      retries: 3", "      start_period: 60s",
                "      start_interval: 2s"]
        out += new
        replaced.add(name)
    elif name.endswith("-db") and name[:-3] in SYSTEMS:
        out += [block[0], '    profiles: ["java-legacy"] # former MySQL of the Java system; volume kept for rollback'] + block[1:]
        profiled.add(name)
    elif name == "serviceregistry":
        out += [l.replace("image: arrowhead-serviceregistry-go:5.2.2-secure-20261015", f"image: {SR_TAG}") for l in block]
    else:
        out += block
    out += tail
    i = j

text = "\n".join(out)
missing = set(SYSTEMS) - replaced
if missing:
    sys.exit(f"services not found: {sorted(missing)}")
text = text.replace("x-system-common: &system-common", ANCHOR + "x-system-common: &system-common", 1)
volumes = "".join(f"  go-{name}-state:\n" for name in SYSTEMS)
text = re.sub(r"\nvolumes:\n", "\nvolumes:\n" + volumes, text, count=1)
open(PATH, "w").write(text)
print(f"replaced {len(replaced)} services, java-legacy profile on {len(profiled)} databases: {sorted(profiled)}")
