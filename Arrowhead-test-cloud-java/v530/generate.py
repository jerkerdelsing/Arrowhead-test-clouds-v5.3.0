#!/usr/bin/env python3
# SPDX-License-Identifier: EPL-2.0
"""Compose definition of the Java test cloud v5.3.0 (Arrowhead-test-clouds/Arrowhead-test-cloud-java, 2026-11-11).

Derived from the fresh 2026-11-09 rebuild (OLD/Arrowhead/Arrowhead-test-cloud-java/fresh-20261109) for a new cloud: own
project name, own cloud CA and secrets, no inter-cloud federation (no relay peers or neighbours; Gatekeeper and GateTunnel
get a relay identity of this cloud's CA only so that they start).

Every core and support system image is built from the primary source Eclipse-Arrowhead-java. Support systems are
deployed as their primary folders define them (compose.yaml of each ah5-<System> folder: app, private MySQL, PKCS#12
stores, file secrets), joined to this cloud's network and credentials. Core systems, brokers and RandomDataProducer keep
this cloud's definition (v530/base-compose.json) with the core images replaced. Output: v530/compose.json.
"""
from __future__ import annotations

import copy
import json
import pathlib
import subprocess

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
PRIMARY = ROOT.parents[1] / "Eclipse-Arrowhead-java"
# v5.3.0 (2026-11-11): every image built from the primary source Eclipse-Arrowhead-java at its current main
TAG = "20261113-r530c"
REGISTRY = "arrowhead-java-v530"
PROJECT = "arrowhead-v53-test-cloud"
X509, STORES, BUNDLES, CRL = ROOT / "security/x509", ROOT / "security/primary-stores", ROOT / "security/bundles", ROOT / "security/crl"

CORE = {"serviceregistry": "serviceregistry", "authentication": "authentication",
        "consumerauthorization": "consumer-authorization", "serviceorchestration-dynamic": "serviceorchestration-dynamic",
        "serviceorchestration-simple": "serviceorchestration-simple"}
# primary folder -> (System, identity secret, store secret, database secret suffix or None)
SUPPORT = {
    "ah5-AIGym-java-spring": ("AIGym", "AH_PW_AIG", "AH_STORE_PW_AIG", None),
    "ah5-Blacklist-java-spring": ("Blacklist", "AH_PW_BL", "AH_STORE_PW_BL", "BLACKLIST"),
    "ah5-CertificateAuthority-java-spring": ("CertificateAuthority", "AH_PW_CAU", "AH_STORE_PW_CERTAUTH", "CERTIFICATEAUTHORITY"),
    "ah5-Choreographer-java-spring": ("Choreographer", "AH_PW_CHO", "AH_STORE_PW_CHO", "CHOREOGRAPHER"),
    "ah5-Configuration-java-spring": ("Configuration", "AH_PW_CFG", "AH_STORE_PW_CFG", "CONFIGURATION"),
    "ah5-DataManager-java-spring": ("DataManager", "AH_PW_DM", "AH_STORE_PW_DM", "DATAMANAGER"),
    "ah5-DeviceQoSEvaluator-java-spring": ("DeviceQoSEvaluator", "AH_PW_DQE", "AH_STORE_PW_DQE", "DEVICEQOSEVALUATOR"),
    "ah5-EventHandler-java-spring": ("EventHandler", "AH_PW_EH", "AH_STORE_PW_EH", "EVENTHANDLER"),
    "ah5-GateTunnel-java-spring": ("GateTunnel", "AH_PW_GT", "AH_STORE_PW_GT", "GATETUNNEL"),
    "ah5-Gatekeeper-java-spring": ("Gatekeeper", "AH_PW_GK", "AH_STORE_PW_GK", "GATEKEEPER"),
    "ah5-GraphDBManager-java-spring": ("GraphDBManager", "AH_PW_GDM", "AH_STORE_PW_GDM", None),
    "ah5-LocalCloudManager-java-spring": ("LocalCloudManager", "AH_PW_LCM", "AH_STORE_PW_LCM", None),
    "ah5-LocalCloudConfigurator-java": ("LocalCloudConfigurator", "AH_PW_LCC", "AH_STORE_PW_LCC", "LOCALCLOUDCONFIGURATOR"),
    "ah5-Onboarding-java-spring": ("Onboarding", "AH_PW_ONB", "AH_STORE_PW_ONB", "ONBOARDING"),
    "ah5-PlantDescriptionEngine-java-spring": ("PlantDescriptionEngine", "AH_PW_PDE", "AH_STORE_PW_PDE", "PLANTDESCRIPTIONENGINE"),
    "ah5-SoLocalCloudConfigurator-java": ("SoLocalCloudConfigurator", "AH_PW_SOLC", "AH_STORE_PW_SOLC", "SOLOCALCLOUDCONFIGURATOR"),
    "ah5-SysMonitor-java-spring": ("SysMonitor", "AH_PW_SM", "AH_STORE_PW_SM", "SYSMONITOR"),
    "ah5-TimeManager-java-spring": ("TimeManager", "AH_PW_TMG", "AH_STORE_PW_TMG", "TIMEMANAGER"),
    "ah5-TranslationManager-java-spring": ("TranslationManager", "AH_PW_TM", "AH_STORE_PW_TM", "TRANSLATIONMANAGER"),
}
CLOUD_POLICY_ENV = ("MANAGEMENT_POLICY", "MANAGEMENT_WHITELIST", "BLACKLIST_CHECK_EXCLUDE_LIST", "ENABLE_BLACKLIST_FILTER",
                    "FORCE_BLACKLIST_FILTER", "SERVICE_AUTHORIZATION_ENABLED", "PLANT_ALARM_IGNORED_SYSTEMS",
                    "NTP_SERVER_LIST", "TIME_TIMEZONE", "CONFIGURATION_MAX_SIZE", "ORCHESTRATION_TIMEOUT",
                    "MANAGED_SERVICES", "ARROWHEAD_ADMIN_SYSTEM")
# SOS-4 (2026-11-10): the CA CRL of each peer cloud, checked by the GateTunnel in the AH-GT-1 key exchange; each
# directory is the one the relay reads (../Arrowhead-relay/compose.yaml)
# v5.3.0: no federation, so no peer cloud CRLs (the GateTunnel checks only this cloud's CRL)
PEER_CRLS: dict[str, tuple[pathlib.Path, str]] = {}
HARDENING = ("user", "read_only", "tmpfs", "cap_drop", "security_opt", "mem_limit", "pids_limit")
# Cloud services kept from ../compose.yaml (everything else is replaced by the primary deployments).
KEEP = set(CORE) | {f"{c}-db" for c in CORE} | {"amqp-broker", "mqtt-broker", "random-data-producer"}
# SOS-16 (2026-11-10): refreshed images of the kept services (the producer from ../random-data-producer, linux/amd64)
KEEP_IMAGES = {
    "amqp-broker": "rabbitmq:4.3.7-alpine@sha256:68fd0566c1c5a5aef2d7b3ad55af8be503a767c1ff8646d7088c8c7946270cf9",
    "mqtt-broker": "eclipse-mosquitto:2.0.22@sha256:81a6193ae693942a3231cd3ac52875b02b7e3a19da671b2fb4b55cc874c5b279",
    "random-data-producer": "arrowhead-random-data-producer:1.0.0-sos16",
}


def render(folder: pathlib.Path) -> dict:
    out = subprocess.run(["docker", "compose", "config", "--format", "json"], cwd=folder, check=True,
                         capture_output=True, text=True).stdout
    return json.loads(out)


def image(folder: str, service: str, primary: dict) -> str:
    base = f"{REGISTRY}/{folder.lower()}"
    if service.endswith("-db"):
        return f"{base}-db:{TAG}"
    if service.endswith("-graphdb"):
        return f"{base}-graphdb:{TAG}"
    if service == "docker-proxy":
        return f"{base}-docker-proxy:{TAG}"
    return f"{base}:{TAG}"


def bind_source(system: str, folder: str, service: str, target: str, source: str) -> tuple[str, bool]:
    """Cloud file for a primary bind target; second value: writable."""
    bundle = {"Gatekeeper": "gatekeeper", "GateTunnel": "gatetunnel"}.get(system)
    if target == f"/certs/{system}.p12" or target == "/certs/truststore.p12":
        return str(STORES / system / pathlib.Path(target).name), False
    if target == "/certs/db-ca.crt":
        return str(X509 / "ca.crt"), False
    if target == "/crl":
        return str(CRL), system == "CertificateAuthority"
    if target in ("/certs/ca.crt", "/certs/ca.key") and system == "CertificateAuthority":
        return str(BUNDLES / "certificate-authority" / pathlib.Path(target).name), False
    if target == "/org-crl":
        # v5.3.0, no federation: the relay identity's "organisation" is this cloud's own CA, so its CRL is this cloud's
        return str(CRL), False
    if bundle and target.startswith(f"/certs/{bundle}-relay") or bundle and target == "/certs/org-ca.crt":
        return str(BUNDLES / bundle / pathlib.Path(target).name), False
    if target.startswith("/tls/"):
        name = {"ca.crt": "ca.crt", "db.crt": "server.crt", "db.key": "server.key"}[pathlib.Path(target).name]
        return str(X509 / "db" / service / name), False
    if target == "/var/run/docker.sock":
        return source, False
    raise SystemExit(f"{service}: no cloud mapping for bind target {target} ({source})")


def secret_name(system: str, ident: str, store: str, db: str | None, key: str) -> str:
    table = {"store-password": store, "identity-password": ident, "console-password-hash": "CONSOLE_PASSWORD_HASH",
             "graphdb-password": "AH_GRAPHDB_PW_GRAPHDBMANAGER", "graphdb-admin-password": "AH_GRAPHDB_ADMIN_GRAPHDBMANAGER"}
    if db:
        table |= {"db-password": f"AH_DB_PW_{db}", "db-root-password": f"AH_DB_ROOT_{db}"}
    if key not in table:
        raise SystemExit(f"{system}: no cloud secret for primary secret {key}")
    return table[key]


def main() -> None:
    # base: the cloud definition before the fresh rebuild (compose.yaml is replaced by the output at deployment)
    cloud = json.loads((HERE / "base-compose.json").read_text())
    old = cloud["services"]
    services = {n: copy.deepcopy(s) for n, s in old.items() if n in KEEP}
    for name, ref in KEEP_IMAGES.items():
        services[name]["image"] = ref
    # v5.3.0, no federation: RandomDataProducer publishes inside this cloud only
    services["random-data-producer"].setdefault("environment", {})["INTERCLOUD_ENABLED"] = "false"
    for name, module in CORE.items():
        services[name]["image"] = f"{REGISTRY}/{module}-java:{TAG}"
        services[name].pop("build", None)
        services[name].pop("platform", None)  # primary builds are native; the amd64 pin belonged to the release base
        services[f"{name}-db"]["image"] = f"{REGISTRY}/{module}-db:{TAG}"  # core-db/Dockerfile
        # SOS-16 (2026-11-10): J14's exclusion names the Spring Boot 4 package of the auto-configuration (the Boot 3 name is
        # ignored by Boot 4, which then logs a generated password)
        env = services[name].get("environment")
        if isinstance(env, dict) and "SPRING_AUTOCONFIGURE_EXCLUDE" in env:
            env["SPRING_AUTOCONFIGURE_EXCLUDE"] = env["SPRING_AUTOCONFIGURE_EXCLUDE"].replace(
                "org.springframework.boot.autoconfigure.security.servlet.UserDetailsServiceAutoConfiguration",
                "org.springframework.boot.security.autoconfigure.UserDetailsServiceAutoConfiguration")
        services[f"{name}-db"].pop("platform", None)
        services[f"{name}-db"].pop("build", None)
    networks = {k: v for k, v in cloud["networks"].items()}
    secrets = dict(cloud.get("secrets", {}))
    for folder, (system, ident, store, db) in SUPPORT.items():
        primary = render(PRIMARY / folder)
        for svc, s in primary["services"].items():
            s.pop("build", None)
            s["image"] = image(folder, svc, primary)
            # networks: cloud -> the cloud network, database/control -> private networks of this deployment
            nets = {}
            for net, cfg in (s.get("networks") or {}).items():
                key = {"cloud": "arrowhead", "control": "console-docker", "console": "console"}.get(
                    net, f"db-{svc if svc.endswith(('-db', '-graphdb')) else svc + '-db'}")
                if net == "database" and not svc.endswith(("-db", "-graphdb")):
                    key = next((f"db-{d}" for d in primary["services"] if d.endswith(("-db", "-graphdb"))), key)
                nets[key] = cfg
                if key == "console":
                    # LocalCloudManager's own network (J6): carries the host-published console port, so not internal
                    networks[key] = {"name": f"{PROJECT}_console", "ipam": {"config": [{"subnet": "10.253.100.0/28"}]}}
                elif key not in networks:
                    networks[key] = {"name": f"{PROJECT}_{key}", "internal": True}
            s["networks"] = nets
            vols = []
            for v in s.get("volumes", []):
                v = dict(v)
                if v["target"] == "/peer-crl" and system == "GateTunnel":
                    for cloud, (directory, _) in PEER_CRLS.items():
                        vols.append({"type": "bind", "source": str(directory), "target": f"/peer-crl/{cloud}",
                                     "read_only": True, "bind": {"create_host_path": False}})
                    continue
                if v["type"] == "volume":
                    v["source"] = f"{svc}-state"
                else:
                    v["source"], writable = bind_source(system, folder, svc, v["target"], v["source"])
                    v["read_only"] = not writable
                    v["bind"] = {"create_host_path": False}
                vols.append(v)
            s["volumes"] = vols
            for sec in s.get("secrets", []):
                cloud_name = secret_name(system, ident, store, db, sec["source"])
                sec["source"] = cloud_name
                secrets.setdefault(cloud_name, {"name": f"{PROJECT}_{cloud_name}", "file": str(ROOT / "secrets" / cloud_name)})
            # host ports: keep this cloud's published port of the same service, container port as built
            # (not LocalCloudConfigurator: the old one is a different generation on 8097; the primary one serves 8492)
            published = {} if system == "LocalCloudConfigurator" else {
                p.get("target"): p.get("published") for p in old.get(svc, {}).get("ports", [])}
            first_old = next(iter(published.values()), None)
            for p in s.get("ports", []):
                p["host_ip"] = "127.0.0.1"
                p["published"] = published.get(p["target"]) or (first_old if len(s["ports"]) == 1 and first_old else p["published"])
            env = s.setdefault("environment", {})
            if system in ("Gatekeeper", "GateTunnel"):
                # v5.3.0: no federation. No neighbours or peer organisations (the primary defaults are empty); the relay
                # identity's trust anchor and CRL are this cloud's own (/org-crl is the cloud CRL directory)
                for k in ("FEDERATION_PEER_ORGANIZATIONS", "NEIGHBOR_CLOUDS", "FEDERATION_FOREIGN_TARGETS"):
                    if k in env:
                        env[k] = ""
                env["RELAY_CRL_FILE"] = "/org-crl/ca.crl"
                if system == "Gatekeeper":
                    env["GATEKEEPER_RELAY_ENABLED"] = "false"
                else:
                    env["RELAY_CRL_FILES"] = "/org-crl/ca.crl"
            # this cloud's deliberate policies for the same service (management access, blacklist filter, ...); the
            # primary defaults do not know them, e.g. DSO's management access to Blacklist (found 2026-11-09)
            old_env = old.get(svc, {}).get("environment") or {}
            for k in CLOUD_POLICY_ENV:
                if k in old_env:
                    env[k] = old_env[k]
            if "CONSOLE_ALLOWED_HOSTS" in env and old_env.get("CONSOLE_ALLOWED_HOSTS"):
                hosts = env["CONSOLE_ALLOWED_HOSTS"].split(",") + old_env["CONSOLE_ALLOWED_HOSTS"].split(",")
                env["CONSOLE_ALLOWED_HOSTS"] = ",".join(dict.fromkeys(h for h in hosts if h))
            if "COMPOSE_PROJECT_NAME" in env:
                env["COMPOSE_PROJECT_NAME"] = PROJECT
            if not svc.endswith(("-db", "-graphdb")) and svc != "docker-proxy":
                deps = s.setdefault("depends_on", {})
                # this cloud's start order (brokers, ConsumerAuthorization, DSO, SysMonitor ...) for the same service
                for dep, cond in old.get(svc, {}).get("depends_on", {}).items():
                    deps.setdefault(dep, cond)  # dependencies on services that no longer exist are dropped below
                deps["serviceregistry"] = {"condition": "service_started", "required": True}
                # primary support systems check Blacklist at start-up and fail closed without it (2026-11-09)
                if system != "Blacklist":
                    deps["blacklist"] = {"condition": "service_healthy", "required": True}
            # container hardening (J3) the primary definition leaves out: its MySQL services run as root with a writable
            # root filesystem and no limits, AIGym has no PID limit (smoke-security, 2026-11-09). Missing keys only,
            # from this cloud's definition of the same service, for new databases from its blacklist-db.
            template = old.get(svc) or (old["blacklist-db"] if svc.endswith("-db") else {})
            for k in HARDENING:
                if k in template and not s.get(k):
                    s[k] = copy.deepcopy(template[k])
            if svc == "localcloudconfigurator":
                # the catalog names the Compose project the configurator and its host worker act on; the primary catalog
                # names the 5.2 cloud's project, so this cloud has its own (v530/localcloud-catalog; install-direct.py
                # --catalog gives the worker the same file, whose hash the API and worker compare)
                s["volumes"].append({"type": "bind", "source": str(HERE / "localcloud-catalog"), "target": "/cloud-catalog",
                                     "read_only": True, "bind": {"create_host_path": False}})
                env["LCC_CATALOG_FILE"] = "/cloud-catalog/javacloud.json"
            if svc == "cloud-monitor-api":
                # 2026-11-11: the SoLC view (System of LocalClouds) replaces the SoS view; it consumes SoLocalCloudConfigurator
                env["SO_LOCAL_CLOUD_CONFIGURATION_ENABLED"] = "true"
            if svc == "solocalcloudconfigurator":
                # packages pin this commit of the primary source for build-on-target and the host assembler
                env["SOLC_SOURCE_COMMIT"] = subprocess.run(["git", "-C", str(PRIMARY), "rev-parse", "HEAD"], check=True,
                                                           capture_output=True, text=True).stdout.strip()
            if svc == "onboarding":
                # manufacturer CRL of the bootstrap certificates, checked fail-closed next to the cloud CA's CRL
                s["volumes"].append({"type": "bind", "source": str(ROOT / "security/manufacturer-crl"),
                                     "target": "/crl-manufacturer", "read_only": True, "bind": {"create_host_path": False}})
                env["ARROWHEAD_SSL_CRL_FILE"] = "/crl/ca.crl,/crl-manufacturer/manufacturer-ca.crl"
            # J7: the stock MySQL entrypoint of the primary database images keeps the *_PASSWORD_FILE values in mysqld's
            # environment; this cloud's wrapper (db/mysql-entrypoint.sh) runs it unchanged but drops them before exec
            if svc.endswith("-db"):
                s["entrypoint"] = ["/usr/local/bin/ah-db-entrypoint.sh"]
                s["command"] = ["mysqld"] + [c for c in s.get("command", []) if c != "mysqld"]
                s["volumes"].append({"type": "bind", "source": str(ROOT / "db/mysql-entrypoint.sh"),
                                     "target": "/usr/local/bin/ah-db-entrypoint.sh", "read_only": True,
                                     "bind": {"create_host_path": False}})
            s.setdefault("labels", {})["eu.arrowhead.primary-source"] = str(PRIMARY / folder)
            if svc in services:
                raise SystemExit(f"duplicate service {svc}")
            services[svc] = s
    for s in services.values():
        if "depends_on" in s:
            s["depends_on"] = {d: c for d, c in s["depends_on"].items() if d in services}
    used = {v["source"] for s in services.values() for v in s.get("volumes", []) if v.get("type") == "volume"}
    volumes = {v: {"name": f"{PROJECT}_{v}"} for v in sorted(used)}
    used_nets = {n for s in services.values() for n in (s.get("networks") or {})}
    used_secrets = {x["source"] for s in services.values() for x in s.get("secrets", [])}
    # Explicit /28 subnets for the internal networks: with three clouds on one Docker host the default address pools are
    # exhausted ("all predefined address pools have been fully subnetted", 2026-11-09). 10.253.0.0/16 is unused here.
    # networks added after the first deployment keep a pinned subnet, so the numbering of the existing ones does not shift
    # (Docker refuses to change the subnet of an existing network; 2026-11-11, SoLocalCloudConfigurator)
    pinned = {"db-solocalcloudconfigurator-db": "10.253.30.0/28"}
    for i, key in enumerate(sorted(k for k in networks if k in used_nets and networks[k].get("internal") and k not in pinned)):
        networks[key] = {**networks[key], "ipam": {"config": [{"subnet": f"10.253.{i}.0/28"}]}}
    for key, subnet in pinned.items():
        if key in networks and key in used_nets:
            networks[key] = {**networks[key], "ipam": {"config": [{"subnet": subnet}]}}
    out = {"name": PROJECT, "services": dict(sorted(services.items())),
           "networks": {k: v for k, v in networks.items() if k in used_nets},
           "volumes": volumes, "secrets": {k: v for k, v in secrets.items() if k in used_secrets}}
    target = HERE / "compose.json"
    target.write_text(json.dumps(out, indent=2) + "\n")
    target.chmod(0o600)
    print(f"{len(services)} services ({len(SUPPORT)} primary support deployments), {len(volumes)} volumes -> {target}")


if __name__ == "__main__":
    main()
