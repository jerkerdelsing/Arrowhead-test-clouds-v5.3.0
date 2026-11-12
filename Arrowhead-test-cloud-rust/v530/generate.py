#!/usr/bin/env python3
# SPDX-License-Identifier: EPL-2.0
"""Rust test cloud v5.3.0 (Arrowhead-test-clouds/Arrowhead-test-cloud-rust, 2026-11-12).

Deployment model of the RustDev cloud (OLD/Arrowhead/Arrowhead-test-cloud-rust/candidate-native, Compose project
arrowhead-v53-test-cloud-rust, which keeps running): one JSON configuration per system, credentials as read-only
files, identities seeded by Authentication's bootstrapIdentities, an internal-only system network and a TCP edge that
publishes loopback ports. Changed for a new cloud:
  - own Compose project, networks and cloud: RustCloud.Company.arrowhead.eu, a new CA (nothing copied from any cloud),
  - every Arrowhead program from the primary source Eclipse-Arrowhead-rust (v530/build.sh, one native image),
    RandomDataProducer, LocalCloudManager and its Docker gateway included; brokers and nginx are upstream images,
  - each system listens on its primary default port (LISTENING-PORTS.md); host ports = default - 2000 (64xx),
    LocalCloudManager API 6480, console 6490, RandomDataProducer 6500, AMQPS 6571, MQTTS 6883, all on 127.0.0.1,
  - no federation: no relay, peers or peer CRLs; intercloud off in DynamicServiceOrchestration and RandomDataProducer,
  - the edge and the console relay are nginx stream proxies (TCP pass-through, no TLS termination, no credentials);
    the console relay is on its own network with LocalCloudManager only and accepts only the host (network gateway),
  - LocalCloudManager is seeded like every other identity (no login as a system is needed to provision it),
  - console password: random, kept only in the macOS keychain (service arrowhead-console-<project>); the manager gets
    its scrypt hash. `make console-password` prints it.

Idempotent: credentials, keys and state are created only when missing; configuration, compose.json, inventory.json,
broker ACLs and edge configuration are rewritten every run. Never prints a secret.
"""
from __future__ import annotations

import base64
import datetime
import hashlib
import json
import os
import pathlib
import secrets
import shutil
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
PROJECT = "arrowhead-v530-test-cloud-rust"
CLOUD, ORG = "RustCloud", "Company"
SUFFIX = f"{CLOUD}.{ORG}.arrowhead.eu"
IMAGE = "arrowhead-rust-v530/rust-systems:20261112-v530"
RABBITMQ = "rabbitmq:4.3.7-alpine@sha256:68fd0566c1c5a5aef2d7b3ad55af8be503a767c1ff8646d7088c8c7946270cf9"
MOSQUITTO = "eclipse-mosquitto:2.0.22@sha256:81a6193ae693942a3231cd3ac52875b02b7e3a19da671b2fb4b55cc874c5b279"
NGINX = "nginx:1.31.8-alpine@sha256:713fc2ebfd92e8217db451477182ee91944b123d2b1ee9fd5a8c6e91ca6c3a11"
CONSOLE_HOST, CONSOLE_PORT = "rustcloud-v530.localhost", 6490
KEYCHAIN_SERVICE = f"arrowhead-console-{PROJECT}"
UID, GID = os.getuid(), os.getgid()
HOST_OFFSET = 2000
# fixed subnets, so the console relay can admit exactly the host (gateway of its network)
SUBNETS = {"arrowhead": "10.241.0.0/24", "manager-control": "10.241.1.0/28", "console": "10.241.2.0/28",
           "edge": "10.241.3.0/28"}
CONSOLE_GATEWAY = "10.241.2.1"

# role, system name, binary, listening port, echo path (None: management probe expecting 401)
SYSTEMS = [
    ("serviceregistry", "ServiceRegistry", "arrowhead-core", 8443, "/serviceregistry/monitor/echo"),
    ("authentication", "Authentication", "arrowhead-core", 8444, "/authentication/monitor/echo"),
    ("consumer-authorization", "ConsumerAuthorization", "arrowhead-core", 8445, "/consumerauthorization/monitor/echo"),
    ("serviceorchestration-dynamic", "DynamicServiceOrchestration", "arrowhead-core", 8441, None),
    ("serviceorchestration-simple", "SimpleStoreServiceOrchestration", "arrowhead-core", 8442, None),
    ("aigym", "AIGym", "arrowhead-support", 8478, "/aigym/monitor/echo"),
    ("blacklist", "Blacklist", "arrowhead-support", 8464, "/blacklist/monitor/echo"),
    ("certificateauthority", "CertificateAuthority", "arrowhead-support", 8448, "/certificate-authority/monitor/echo"),
    ("choreographer", "Choreographer", "arrowhead-support", 8457, "/choreographer/monitor/echo"),
    ("configuration", "Configuration", "arrowhead-support", 8459, "/configuration/monitor/echo"),
    ("datamanager", "DataManager", "arrowhead-support", 8461, "/datamanager/monitor/echo"),
    ("deviceqosevaluator", "DeviceQoSEvaluator", "arrowhead-support", 8472, "/deviceqosevaluator/monitor/echo"),
    ("eventhandler", "EventHandler", "arrowhead-support", 8455, "/eventhandler/monitor/echo"),
    ("gatekeeper", "Gatekeeper", "arrowhead-support", 8449, "/gatekeeper/monitor/echo"),
    ("gatetunnel", "GateTunnel", "arrowhead-support", 8453, "/gatetunnel/monitor/echo"),
    ("onboarding", "Onboarding", "arrowhead-support", 8435, "/onboarding/monitor/echo"),
    ("plantdescriptionengine", "PlantDescriptionEngine", "arrowhead-support", 8432, "/plantdescriptionengine/monitor/echo"),
    ("sysmonitor", "SysMonitor", "arrowhead-support", 8475, "/sysmonitor/monitor/echo"),
    ("timemanager", "TimeManager", "arrowhead-support", 8463, "/timemanager/monitor/echo"),
    ("translationmanager", "TranslationManager", "arrowhead-support", 8465, "/translation/monitor/echo"),
]
MGMT_PREFIX = {"serviceregistry": "/serviceregistry", "authentication": "/authentication",
               "consumer-authorization": "/consumerauthorization", "serviceorchestration-dynamic": "/serviceorchestration",
               "serviceorchestration-simple": "/serviceorchestration", "certificateauthority": "/certificate-authority",
               "translationmanager": "/translation"}
LCM = ("localcloudmanager", "LocalCloudManager", 8480)
CONSOLE_LISTEN = 8490
RDP = ("random-data-producer", "RandomDataProducer", 8500)
CLIENTS = [("sysop", "Sysop", "op"), ("test-provider", "TestProvider", "sy"), ("test-consumer", "TestConsumer", "sy")]
BROKERS = [("amqp-broker", "AmqpBroker", 5671, 6571), ("mqtt-broker", "MqttBroker", 8883, 6883)]
PORT = {r: p for r, _, _, p, _ in SYSTEMS} | {LCM[0]: LCM[2], RDP[0]: RDP[2]}
NAME = {r: n for r, n, _, _, _ in SYSTEMS} | {LCM[0]: LCM[1], RDP[0]: RDP[1]}

# management whitelists and extra settings as in the running RustDev cloud, without federation
WHITELIST = {
    "serviceregistry": ["LocalCloudManager", "Onboarding"],
    "authentication": ["Onboarding"],
    "blacklist": ["Onboarding"],
    "consumer-authorization": ["ServiceRegistry", "DynamicServiceOrchestration", "SimpleStoreServiceOrchestration",
                               "EventHandler", "LocalCloudManager"],
    "gatekeeper": ["LocalCloudManager"], "gatetunnel": ["LocalCloudManager"],
    "plantdescriptionengine": ["LocalCloudManager"], "serviceorchestration-dynamic": ["LocalCloudManager"],
    "serviceorchestration-simple": ["LocalCloudManager"], "sysmonitor": ["LocalCloudManager"],
}


def url(role: str) -> str:
    return f"https://{role}:{PORT[role]}/"


UPSTREAMS = {
    "gatekeeper": ["gatetunnel"],
    "onboarding": ["certificateauthority", "blacklist"],
    "plantdescriptionengine": ["serviceorchestration-dynamic"],
    "sysmonitor": ["serviceorchestration-dynamic"],
}
MESSAGING = dict(amqpHost="amqp-broker", amqpPort=5671, amqpIdentity="AmqpBroker", mqttHost="mqtt-broker",
                 mqttPort=8883, mqttIdentity="MqttBroker", intervalSeconds=30, defaultSubscription="all",
                 retentionDays=30)
LOGGING = {"driver": "json-file", "options": {"max-size": "5m", "max-file": "2"}}
HARDENING = {"read_only": True, "cap_drop": ["ALL"], "security_opt": ["no-new-privileges:true"],
             "restart": "unless-stopped", "logging": LOGGING}


def write(path: pathlib.Path, text: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(mode)


def openssl(*args) -> None:
    r = subprocess.run(["openssl", *map(str, args)], capture_output=True)
    if r.returncode:
        raise SystemExit("openssl failed: " + r.stderr.decode(errors="replace")[-400:])


def subject_rfc2253(cert: pathlib.Path) -> str:
    out = subprocess.check_output(["openssl", "x509", "-in", cert, "-noout", "-subject", "-nameopt", "RFC2253"],
                                  text=True)
    return out.strip().split("=", 1)[1].strip()


# ---------------------------------------------------------------- credentials (created once)
def pki() -> None:
    s = ROOT / "secrets"
    s.mkdir(mode=0o700, exist_ok=True)
    s.chmod(0o700)
    ca_key, ca = s / "ca.key", s / "ca.pem"
    if not ca.exists():
        cnf = s / "ca.cnf"
        write(cnf, "[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=v3\n[dn]\n"
                   f"CN={CLOUD} Rust v5.3.0 Test Cloud CA\nO={ORG}\n"
                   "[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n"
                   "subjectKeyIdentifier=hash\n")
        openssl("req", "-x509", "-newkey", "rsa:3072", "-nodes", "-keyout", ca_key, "-out", ca, "-days", 730,
                "-config", cnf)
        ca_key.chmod(0o600)
        ca.chmod(0o644)
    serial = 1000
    identities = [(r, NAME[r], "sy", [r]) for r in PORT] + [(r, n, "sy", [r]) for r, n, _, _ in BROKERS] \
        + [(r, n, p, [r]) for r, n, p in CLIENTS]
    for role, name, profile, dns in identities:
        serial += 1
        d = s / role
        d.mkdir(mode=0o700, exist_ok=True)
        if (d / "cert.pem").exists():
            continue
        names = dns + ["localhost"] + ([CONSOLE_HOST] if role == "localcloudmanager" else [])
        san = ",".join(f"DNS:{n}" for n in names) + ",IP:127.0.0.1"
        write(d / "extensions.cnf", "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,"
              f"keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName={san}\n"
              "authorityKeyIdentifier=keyid\nsubjectKeyIdentifier=hash\n")
        openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", d / "key.pem", "-out", d / "request.pem",
                "-subj", f"/CN={name}.{SUFFIX}/dnQualifier={profile}")
        openssl("x509", "-req", "-in", d / "request.pem", "-CA", ca, "-CAkey", ca_key, "-set_serial", serial,
                "-out", d / "cert.pem", "-days", 365, "-extfile", d / "extensions.cnf")
        for f in ("key.pem", "cert.pem"):
            (d / f).chmod(0o600)
        if not any(role == b[0] for b in BROKERS):
            write(d / "password", secrets.token_urlsafe(36))
    if not (s / "token-secret").exists():
        write(s / "token-secret", secrets.token_urlsafe(48))
    lcm = s / "localcloudmanager"
    if not (lcm / "docker-token").exists():
        write(lcm / "docker-token", secrets.token_urlsafe(36))
    if not (lcm / "console.hash").exists():
        console_password()
    manufacturer()
    crl()


def console_password() -> None:
    """Random console password into the keychain only; the manager receives its scrypt hash."""
    password = secrets.token_urlsafe(24)
    # `security -i` reads the command from stdin, so the password is not in any process's arguments
    cmd = f"add-generic-password -U -s {KEYCHAIN_SERVICE} -a {PROJECT} -l {KEYCHAIN_SERVICE} -w {password}\n"
    r = subprocess.run(["security", "-i"], input=cmd, text=True, capture_output=True)
    check = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"], capture_output=True,
                           text=True)
    if r.returncode or check.stdout.strip() != password:
        raise SystemExit("could not store the console password in the keychain")
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1, dklen=32)
    write(ROOT / "secrets/localcloudmanager/console.hash",
          f"scrypt:{base64.b64encode(salt).decode()}:{base64.b64encode(digest).decode()}\n")


def manufacturer() -> None:
    """Onboarding's bootstrap trust: a manufacturer CA of this test cloud (no device is issued here) and its CRL."""
    m = ROOT / "secrets/manufacturer"
    pub = m / "public"
    if (pub / "manufacturer-ca.pem").exists():
        return
    pub.mkdir(parents=True, exist_ok=True)
    m.chmod(0o700)
    write(m / "ca.cnf", "[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=v3\n[dn]\n"
          f"CN={CLOUD} Test Manufacturer CA\n[v3]\nbasicConstraints=critical,CA:TRUE\n"
          "keyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n")
    openssl("req", "-x509", "-newkey", "rsa:3072", "-nodes", "-keyout", m / "ca.key", "-out",
            pub / "manufacturer-ca.pem", "-days", 730, "-config", m / "ca.cnf")
    (m / "ca.key").chmod(0o600)
    gen_crl(m / "ca.key", pub / "manufacturer-ca.pem", pub / "manufacturer-ca.crl.pem", m / "db")
    pub.chmod(0o755)
    for f in pub.iterdir():
        f.chmod(0o644)


def gen_crl(key: pathlib.Path, cert: pathlib.Path, out: pathlib.Path, db: pathlib.Path) -> None:
    db.mkdir(mode=0o700, exist_ok=True)
    (db / "index.txt").touch()
    if not (db / "crlnumber").exists():
        (db / "crlnumber").write_text("1000\n")
    cnf = db / "crl.cnf"
    cnf.write_text(f"[ca]\ndefault_ca=c\n[c]\ndatabase={db}/index.txt\ncrlnumber={db}/crlnumber\n"
                   "default_md=sha256\ndefault_crl_days=30\n")
    openssl("ca", "-gencrl", "-config", cnf, "-keyfile", key, "-cert", cert, "-out", out)


def crl() -> None:
    """Initial issuer CRL; CertificateAuthority republishes it (crlPublishFile) after start and every 60 s."""
    trust = ROOT / "trust"
    trust.mkdir(exist_ok=True)
    trust.chmod(0o755)
    out = trust / "current.crl.pem"
    if not out.exists():
        gen_crl(ROOT / "secrets/ca.key", ROOT / "secrets/ca.pem", out, ROOT / "secrets/ca-db")
        out.chmod(0o644)


# ---------------------------------------------------------------- configuration (rewritten)
def base_config(role: str, name: str) -> dict:
    return dict(role=role, name=name, cloudSuffix=SUFFIX, listen=f"0.0.0.0:{PORT[role]}", certificate="/run/cert.pem",
                privateKey="/run/key.pem", ca="/run/ca.pem", state="/data/state.json", passwordFile="/run/password",
                authenticationUrl=url("authentication"), registryUrl=url("serviceregistry"),
                authorizationUrl=url("consumer-authorization"), managementWhitelist=WHITELIST.get(role, []),
                register=True, advertiseAddress=role, advertisePort=PORT[role],
                upstreams={NAME[u]: url(u) for u in UPSTREAMS.get(role, [])},
                crlFile="/run/trust/current.crl.pem", messaging=MESSAGING)


def bootstrap_seeds() -> list[tuple[str, str, bool]]:
    return [(r, NAME[r], False) for r in PORT] + [(r, n, p == "op") for r, n, p in CLIENTS]


def configs() -> dict[str, dict]:
    out = {}
    for role, name, _, _, _ in SYSTEMS:
        c = base_config(role, name)
        if role == "authentication":
            c["bootstrapIdentities"] = [dict(systemName=n, passwordFile=f"/run/bootstrap/{r}", sysop=op)
                                        for r, n, op in bootstrap_seeds()]
        elif role == "serviceregistry":
            c["discoveryDirectAccess"] = ["Authentication", "ConsumerAuthorization", "DynamicServiceOrchestration",
                                          "SimpleStoreServiceOrchestration"]
        elif role == "consumer-authorization":
            c["tokenSecretFile"] = "/run/token-secret"
        elif role == "certificateauthority":
            c.update(caCertificate="/run/ca.pem", caSigningKey="/run/ca-signing.key",
                     crlPublishFile="/run/trust/current.crl.pem")
        elif role == "onboarding":
            c.update(bootstrapCa="/run/manufacturer/manufacturer-ca.pem",
                     bootstrapCrl="/run/manufacturer/manufacturer-ca.crl.pem")
        elif role == "serviceorchestration-dynamic":
            c["intercloudEnabled"] = False
        out[role] = c
    out[LCM[0]] = dict(
        cloudSuffix=SUFFIX, project=PROJECT, listen=f"0.0.0.0:{LCM[2]}", consoleListen=f"0.0.0.0:{CONSOLE_LISTEN}",
        certificate="/run/cert.pem", privateKey="/run/key.pem", ca="/run/ca.pem", passwordFile="/run/password",
        consoleHashFile="/run/console.hash", consoleOrigins=[f"https://{CONSOLE_HOST}:{CONSOLE_PORT}"],
        consoleClients=["console-proxy"],
        upstreams={NAME[r]: url(r) for r in [s[0] for s in SYSTEMS] + [RDP[0]]},
        dockerUrl="http://manager-docker-proxy:8080/", dockerTokenFile="/run/gateway-token",
        advertiseAddress="localcloudmanager", advertisePort=LCM[2], crlFile="/run/trust/current.crl.pem",
        messaging=MESSAGING)
    out[RDP[0]] = dict(
        name=RDP[1], cloudSuffix=SUFFIX, listen=f"0.0.0.0:{RDP[2]}", certificate="/run/cert.pem",
        privateKey="/run/key.pem", ca="/run/ca.pem", crlFile="/run/trust/current.crl.pem", passwordFile="/run/password",
        state="/data/state.json", authenticationUrl=url("authentication"), registryUrl=url("serviceregistry"),
        authorizationUrl=url("consumer-authorization"), orchestratorUrl=url("serviceorchestration-dynamic"),
        advertiseAddress=RDP[0], advertisePort=RDP[2], intervalSeconds=30, intercloudEnabled=False,
        messaging=MESSAGING)
    return out


def broker_policies() -> None:
    """RabbitMQ users (certificate DN, EXTERNAL) and Mosquitto ACL, as in the RustDev cloud."""
    defs = dict(vhosts=[dict(name="/")], exchanges=[dict(name="arrowhead", vhost="/", type="topic", durable=True,
                auto_delete=False, internal=False, arguments={})], users=[], permissions=[], topic_permissions=[])
    acl = []
    for role in PORT:
        name = NAME[role]
        subject = subject_rfc2253(ROOT / "secrets" / role / "cert.pem")
        user = subject.replace("dnQualifier=", "2.5.4.46=")
        sm = name == "SysMonitor"
        defs["users"].append(dict(name=user, password_hash="", hashing_algorithm="rabbit_password_hashing_sha256",
                                  tags=[]))
        defs["permissions"].append(dict(user=user, vhost="/", configure=r"^SysMonitor\.observations$" if sm else "^$",
                                        write=r"^(arrowhead|SysMonitor\.observations)$" if sm else "^arrowhead$",
                                        read=r"^(arrowhead|SysMonitor\.observations)$" if sm else "^$"))
        defs["topic_permissions"].append(dict(
            user=user, vhost="/", exchange="arrowhead",
            write=rf"^{CLOUD}\.sysmonitor\.{name}\.{name}\.(echo|power|status)$",
            read=rf"^{CLOUD}\.sysmonitor\.[A-Za-z][A-Za-z0-9_]*\.[A-Za-z][A-Za-z0-9_]*\.(echo|power|status)$"
            if sm else "^$"))
        if sm:
            acl.append(f"user {subject}\ntopic write arrowhead/{CLOUD}/sysmonitor/data/+/+\n")
        if name == "AIGym":
            acl.append(f"user {subject}\ntopic read arrowhead/{CLOUD}/sysmonitor/data/+/+\n")
    write(ROOT / "amqp/definitions.json", json.dumps(defs, indent=2) + "\n", 0o644)
    write(ROOT / "mqtt/acl", "\n".join(acl), 0o644)


def broker_files() -> None:
    a, m = ROOT / "amqp", ROOT / "mqtt"
    write(a / "rabbitmq.conf", "listeners.tcp = none\nlisteners.ssl.default = 5671\nauth_mechanisms.1 = EXTERNAL\n"
          "ssl_cert_login_from = distinguished_name\nload_definitions = /etc/rabbitmq/definitions.json\n"
          "loopback_users = none\nlog.console = true\nlog.console.level = warning\n", 0o644)
    write(a / "advanced.config", '[{rabbit, [{ssl_options, [{cacertfile, "/run/ca.pem"},\n'
          ' {certfile, "/run/broker/cert.pem"}, {keyfile, "/run/broker/key.pem"},\n'
          " {verify, verify_peer}, {fail_if_no_peer_cert, true},\n {versions, ['tlsv1.3','tlsv1.2']},"
          " {crl_check, peer},\n {crl_cache, {ssl_crl_hash_dir, {internal, [{dir, \"/tmp/rabbitmq-crl\"}]}}}]}]}].\n",
          0o644)
    write(a / "enabled_plugins", "[rabbitmq_auth_mechanism_ssl].\n", 0o644)
    write(a / "entrypoint.sh", "#!/bin/sh\nset -eu\nmkdir -p /tmp/rabbitmq-crl\n"
          'ln -sf /run/trust/current.crl.pem "/tmp/rabbitmq-crl/$(openssl x509 -in /run/ca.pem -noout -hash).r0"\n'
          "exec docker-entrypoint.sh rabbitmq-server\n", 0o755)
    write(m / "mosquitto.conf", "persistence true\npersistence_location /mosquitto/data/\nlog_dest stdout\n"
          "listener 8883 0.0.0.0\nprotocol mqtt\nallow_anonymous false\nrequire_certificate true\n"
          "use_subject_as_username true\ncafile /run/ca.pem\ncertfile /run/broker/cert.pem\n"
          "keyfile /run/broker/key.pem\ntls_version tlsv1.2\ncrlfile /tmp/arrowhead-crl.pem\n"
          "acl_file /mosquitto/config/acl\nmax_packet_size 1048576\nmax_queued_messages 1000\n", 0o644)
    # reloads the broker when CertificateAuthority republishes the CRL (as in the RustDev cloud)
    write(m / "entrypoint.sh", """#!/bin/sh
set -eu
test -s /run/trust/current.crl.pem
cp /run/trust/current.crl.pem /tmp/arrowhead-crl.pem
broker=$$
(
  last=$(cksum /run/trust/current.crl.pem)
  while sleep 2; do
    if [ ! -s /run/trust/current.crl.pem ]; then kill -TERM "$broker"; exit 1; fi
    current=$(cksum /run/trust/current.crl.pem)
    if [ "$current" != "$last" ]; then
      cp /run/trust/current.crl.pem /tmp/crl.pending
      mv /tmp/crl.pending /tmp/arrowhead-crl.pem
      kill -HUP "$broker" || exit 0
      last=$current
    fi
  done
) &
exec /usr/sbin/mosquitto -c /mosquitto/config/mosquitto.conf
""", 0o755)


def edge_files() -> None:
    """nginx stream (TCP pass-through) configurations of the edge and the console relay."""
    common = ("worker_processes 1;\npid /tmp/nginx.pid;\nerror_log /dev/stderr warn;\n"
              "events { worker_connections 512; }\n")
    lines = [f"# generated by v530/generate.py; TCP pass-through only (TLS end to end, no credentials here)\n{common}",
             "stream {\n  resolver 127.0.0.11 valid=10s ipv6=off;\n  proxy_connect_timeout 5s;\n  proxy_timeout 65s;\n"]
    for role, host_port, target in edge_ports():
        lines.append(f"  server {{ listen {host_port}; set $u {role}:{target}; proxy_pass $u; }}\n")
    lines.append("}\n")
    write(ROOT / "edge/nginx.conf", "".join(lines), 0o644)
    write(ROOT / "edge/console.conf",
          "# generated by v530/generate.py. LocalCloudManager's HTTPS console, TCP pass-through (TLS ends in the manager).\n"
          f"# Only the host: a published port arrives from the gateway of this network ({CONSOLE_GATEWAY}).\n"
          f"{common}stream {{\n  resolver 127.0.0.11 valid=10s ipv6=off;\n  server {{\n    listen {CONSOLE_LISTEN};\n"
          f"    allow {CONSOLE_GATEWAY};\n    allow 127.0.0.1;  # own health check\n    deny all;\n    set $u localcloudmanager:{CONSOLE_LISTEN};\n"
          "    proxy_pass $u;\n    proxy_connect_timeout 5s;\n    proxy_timeout 65s;\n  }\n}\n", 0o644)


def edge_ports() -> list[tuple[str, int, int]]:
    out = [(r, p - HOST_OFFSET, p) for r, p in PORT.items()]
    out += [(r, h, c) for r, _, c, h in BROKERS]
    return out


# ---------------------------------------------------------------- compose
def bind(source: str, target: str, ro: bool = True) -> dict:
    return {"type": "bind", "source": source, "target": target, "read_only": ro, "bind": {"create_host_path": False}}


def creds(role: str) -> list[dict]:
    return [bind(f"./secrets/{role}/cert.pem", "/run/cert.pem"), bind(f"./secrets/{role}/key.pem", "/run/key.pem"),
            bind(f"./secrets/{role}/password", "/run/password"), bind("./secrets/ca.pem", "/run/ca.pem"),
            bind("./trust", "/run/trust", ro=(role != "certificateauthority"))]


def curl_health(port: int, path: str, expect: str, cert: bool = True) -> dict:
    c = "--cert /run/cert.pem --key /run/key.pem " if cert else ""
    return {"test": ["CMD-SHELL", f'test "$$(curl --crlfile /run/trust/current.crl.pem --silent --output /dev/null '
                     f'--write-out "%{{http_code}}" --max-time 5 --cacert /run/ca.pem {c}https://localhost:{port}{path})"'
                     f' = "{expect}"'],
            "interval": "15s", "timeout": "7s", "retries": 5, "start_period": "60s", "start_interval": "2s"}


def system_service(role: str, binary: str, echo: str | None) -> dict:
    vols = creds(role) + [bind(f"./config/{role}.json", "/run/config.json"), bind(f"./state/{role}", "/data", False)]
    if role == "authentication":
        vols += [bind(f"./secrets/{r}/password", f"/run/bootstrap/{r}") for r, _, _ in bootstrap_seeds()]
    if role == "consumer-authorization":
        vols.append(bind("./secrets/token-secret", "/run/token-secret"))
    if role == "certificateauthority":
        vols.append(bind("./secrets/ca.key", "/run/ca-signing.key"))
    if role == "onboarding":
        vols.append(bind("./secrets/manufacturer/public", "/run/manufacturer"))
    probe = echo or (MGMT_PREFIX.get(role, "/" + role) + "/general/mgmt/get-config")
    return {"image": IMAGE, "entrypoint": [f"/usr/local/bin/{binary}"], "command": ["--config", "/run/config.json"],
            "user": f"{UID}:{GID}", **HARDENING, "pids_limit": 128,
            "mem_limit": "512m" if role in ("authentication", "gatetunnel") else "256m", "cpus": 1,
            "stop_grace_period": "45s", "tmpfs": ["/tmp:rw,noexec,nosuid,size=16m"],
            "labels": {"eu.arrowhead.primary-source": "Eclipse-Arrowhead-rust"},
            "networks": {"arrowhead": {}}, "volumes": vols,
            "healthcheck": curl_health(PORT[role], probe, "200" if echo else "401")}


def services() -> dict:
    out = {}
    for role, _, binary, _, echo in SYSTEMS:
        out[role] = system_service(role, binary, echo)
    rdp = system_service(RDP[0], "RandomDataProducer", None)
    rdp["entrypoint"] = ["/usr/local/bin/RandomDataProducer"]
    rdp["healthcheck"] = curl_health(RDP[2], "/health", "200")
    rdp["healthcheck"]["start_period"] = "120s"
    out[RDP[0]] = rdp
    lcm = {"image": IMAGE, "entrypoint": ["/usr/local/bin/LocalCloudManager"], "command": ["--config", "/run/config.json"],
           "user": f"{UID}:{GID}", **HARDENING, "pids_limit": 128, "mem_limit": "256m", "cpus": 1,
           "stop_grace_period": "20s", "tmpfs": ["/tmp:rw,noexec,nosuid,size=16m"],
           "labels": {"eu.arrowhead.primary-source": "Eclipse-Arrowhead-rust"},
           "networks": {"arrowhead": {}, "manager-control": {}, "console": {}},
           "volumes": creds(LCM[0]) + [bind("./config/localcloudmanager.json", "/run/config.json"),
              bind("./secrets/localcloudmanager/console.hash", "/run/console.hash"),
              bind("./secrets/localcloudmanager/docker-token", "/run/gateway-token")],
           "depends_on": {"manager-docker-proxy": {"condition": "service_healthy"}},
           "healthcheck": {"test": ["CMD", "curl", "--crlfile", "/run/trust/current.crl.pem", "--fail", "--silent",
                                    "--max-time", "5", "--cacert", "/run/ca.pem",
                                    f"https://localhost:{CONSOLE_LISTEN}/health"],
                           "interval": "15s", "timeout": "7s", "retries": 5, "start_period": "60s",
                           "start_interval": "2s"}}
    out[LCM[0]] = lcm
    out["manager-docker-proxy"] = {
        "image": IMAGE, "entrypoint": ["/usr/local/bin/localcloudmanager-docker-proxy"], "user": f"{UID}:0",
        **HARDENING, "pids_limit": 64, "mem_limit": "64m", "cpus": 1,
        "labels": {"eu.arrowhead.primary-source": "Eclipse-Arrowhead-rust"},
        "environment": {"CANDIDATE_PROJECT": PROJECT, "DOCKER_SOCKET": "/var/run/docker.sock",
                        "GATEWAY_TOKEN_FILE": "/run/gateway-token"},
        "networks": {"manager-control": {}},
        "volumes": [bind("./secrets/localcloudmanager/docker-token", "/run/gateway-token"),
                    {"type": "bind", "source": "/var/run/docker.sock", "target": "/var/run/docker.sock",
                     "read_only": True}],
        "healthcheck": {"test": ["CMD-SHELL", 'test "$$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 '
                                 'http://127.0.0.1:8080/containers)" = "401"'],
                        "interval": "15s", "timeout": "5s", "retries": 5, "start_period": "10s"}}
    for role, _, port, _ in BROKERS:
        b = {"user": f"{UID}:{GID}", **HARDENING, "networks": {"arrowhead": {}},
             "tmpfs": ["/tmp:rw,nosuid,nodev,size=64m"],
             "volumes": [bind(f"./secrets/{role}", "/run/broker"), bind("./secrets/ca.pem", "/run/ca.pem"),
                         bind("./trust", "/run/trust")]}
        if role == "amqp-broker":
            b.update(image=RABBITMQ, hostname=role, entrypoint=["/etc/rabbitmq/entrypoint.sh"], pids_limit=512,
                     mem_limit="512m", cpus=2,
                     environment={"ERL_EPMD_ADDRESS": "127.0.0.1", "RABBITMQ_NODENAME": "rabbit@localhost",
                                  "RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS":
                                      "-kernel inet_dist_use_interface {127,0,0,1} +S 2:2 +A 4"},
                     healthcheck={"test": ["CMD", "rabbitmq-diagnostics", "-q", "check_port_listener", "5671"],
                                  "interval": "10s", "timeout": "8s", "retries": 12, "start_period": "30s"})
            b["volumes"] += [bind("./amqp", "/etc/rabbitmq"), bind("./state/amqp-broker", "/var/lib/rabbitmq", False)]
        else:
            b.update(image=MOSQUITTO, entrypoint=["/mosquitto/config/entrypoint.sh"], pids_limit=64, mem_limit="192m",
                     cpus=1, healthcheck={"test": ["CMD", "nc", "-z", "-w", "2", "127.0.0.1", "8883"],
                                          "interval": "10s", "timeout": "4s", "retries": 8, "start_period": "5s"})
            b["volumes"] += [bind("./mqtt", "/mosquitto/config"), bind("./state/mqtt-broker", "/mosquitto/data", False)]
        out[role] = b
    nginx = {"image": NGINX, "entrypoint": ["nginx", "-g", "daemon off;"], "user": "101:101", **HARDENING,
             "pids_limit": 64, "mem_limit": "64m", "cpus": 1, "tmpfs": ["/tmp:rw,nosuid,nodev,mode=1777,size=8m"]}
    out["edge"] = nginx | {
        "volumes": [bind("./edge/nginx.conf", "/etc/nginx/nginx.conf")],
        "networks": {"arrowhead": {}, "edge": {}},
        "ports": [{"target": h, "published": str(h), "protocol": "tcp", "host_ip": "127.0.0.1"}
                  for _, h, _ in edge_ports()],
        "healthcheck": {"test": ["CMD-SHELL", "nc -z 127.0.0.1 6443 && nc -z 127.0.0.1 6444"],
                        "interval": "15s", "timeout": "5s", "retries": 5, "start_period": "10s"}}
    out["console-proxy"] = nginx | {
        "volumes": [bind("./edge/console.conf", "/etc/nginx/nginx.conf")],
        "networks": {"console": {"ipv4_address": "10.241.2.10"}},
        "ports": [{"target": CONSOLE_LISTEN, "published": str(CONSOLE_PORT), "protocol": "tcp", "host_ip": "127.0.0.1"}],
        "depends_on": {"localcloudmanager": {"condition": "service_healthy"}},
        "healthcheck": {"test": ["CMD", "nc", "-z", "127.0.0.1", str(CONSOLE_LISTEN)],
                        "interval": "15s", "timeout": "5s", "retries": 5, "start_period": "10s"}}
    return out


def compose() -> dict:
    nets = {}
    for n, subnet in SUBNETS.items():
        nets[n] = {"name": f"{PROJECT}_{n}", "ipam": {"config": [{"subnet": subnet}]}}
        if n in ("arrowhead", "manager-control"):
            nets[n]["internal"] = True  # systems and the Docker gateway: no route outside
    return {"name": PROJECT, "services": services(), "networks": nets}


def main() -> None:
    os.umask(0o077)
    pki()
    for role in list(PORT) + [b[0] for b in BROKERS]:
        (ROOT / "state" / role).mkdir(parents=True, exist_ok=True, mode=0o700)
    for role, c in configs().items():
        write(ROOT / "config" / f"{role}.json", json.dumps(c, indent=2) + "\n", 0o644)
    broker_files()
    broker_policies()
    edge_files()
    target = ROOT / "compose.json"
    if target.exists() and "arrowhead-v530-test-cloud-rust" not in target.read_text():
        shutil.copy2(target, ROOT / f"compose.json.before-rust530-{datetime.date.today():%Y%m%d}")
    write(target, json.dumps(compose(), indent=2) + "\n", 0o644)
    inventory = [dict(role=r, name=NAME[r], port=PORT[r], hostPort=PORT[r] - HOST_OFFSET, echo=e,
                      management=MGMT_PREFIX.get(r, "/" + r) + "/general/mgmt/get-config")
                 for r, _, _, _, e in SYSTEMS]
    inventory += [dict(role=LCM[0], name=LCM[1], port=LCM[2], hostPort=LCM[2] - HOST_OFFSET, echo=None,
                       management=None, consoleHost=CONSOLE_HOST, consolePort=CONSOLE_PORT),
                  dict(role=RDP[0], name=RDP[1], port=RDP[2], hostPort=RDP[2] - HOST_OFFSET, echo=None, management=None)]
    inventory += [dict(role=r, name=n, port=c, hostPort=h, broker=True) for r, n, c, h in BROKERS]
    write(ROOT / "inventory.json", json.dumps(dict(project=PROJECT, cloud=CLOUD, suffix=SUFFIX,
                                                   keychainService=KEYCHAIN_SERVICE, systems=inventory), indent=2)
          + "\n", 0o644)
    print(f"{len(compose()['services'])} services -> {target}; credentials in secrets/ (not printed)")


if __name__ == "__main__":
    main()
