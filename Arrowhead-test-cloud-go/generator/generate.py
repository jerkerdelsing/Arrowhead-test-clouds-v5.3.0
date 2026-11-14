#!/usr/bin/env python3
# SPDX-License-Identifier: EPL-2.0
"""Compose definition of the Go test cloud v5.3.0 (Arrowhead-test-clouds/Arrowhead-test-cloud-go, 2026-11-11).

Base: generator/base-compose.json, the definition of the running 5.2 GoCloud (OLD/Arrowhead/Arrowhead-test-cloud-go,
redeploy-20261110-sos16/go-compose.json, written from `docker inspect` of its 27 services). Changed for a new cloud:
  - own Compose project, network, volumes and secrets; host ports 9xxx -> 7xxx (6671 -> 7671); paths in this folder,
  - every core and support system image built from the primary source Eclipse-Arrowhead-go (generator/build.sh), native
    platform; brokers and RandomDataProducer unchanged,
  - no federation: no peer CRLs, neighbours or relay settings (federationEnabled=false in runtime-go, make-go-runtime.sh),
    RandomDataProducer with INTERCLOUD_ENABLED=false,
  - console: the primary LocalCloudManager-go (launcher generator/console/launcher) behind a loopback proxy with a client
    certificate (generator/console/proxy) in place of the 5.2 cloud's Node.js cloud-monitor-api/ui, which are not built from
    a primary source; the whitelisting docker-proxy is kept,
  - ServiceRegistry with the same TCP health check as the other Go systems.
Output: ../compose.yaml (YAML; the scripts read its secrets block). The previous file is kept as compose.yaml.before-*.
"""
from __future__ import annotations

import copy
import datetime
import json
import pathlib
import shutil

import yaml

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
OLD_ROOT = "/Users/jerkerdelsing/Work/lule/EISLAB/Project/Eclipse/OLD/Arrowhead/Arrowhead-test-cloud-go"
OLD_PROJECT = "arrowhead-v52-test-cloud-go"
PROJECT = "arrowhead-v53-test-cloud-go"
TAG, REGISTRY = "20261114-v540", "arrowhead-go-v530"
OLD_IMAGE_PREFIX, OLD_TAG = "arrowhead-test-redeploy/", ":20261110-sos16"
CONSOLE_HOST, CONSOLE_PORT = "gocloud-v53.localhost", "7490"
NGINX = "nginx:1.31.8-alpine@sha256:713fc2ebfd92e8217db451477182ee91944b123d2b1ee9fd5a8c6e91ca6c3a11"
DROP = {"cloud-monitor-api", "cloud-monitor-ui"}
NETWORKS = {"n0": "arrowhead", "n1": "console-docker", "n2": "console"}
SECRET_BINDS = {"AH_AUTHENTICATION_SECRET_KEY", "AH_PW_SR", "AH_PW_RDP"}


def host_port(published: str) -> str:
    p = int(published)
    return str({6671: 7671, 9883: 7883}.get(p, p - 2000 if 9000 <= p < 10000 else p))


def bind_source(source: str) -> str:
    source = source.removeprefix("/host_mnt")
    if not source.startswith(OLD_ROOT + "/"):
        if source == "/var/run/docker.sock":
            return source
        raise SystemExit(f"no mapping for bind source {source}")
    return "./" + source[len(OLD_ROOT) + 1:]


def convert(name: str, s: dict, secrets: set[str]) -> dict:
    s = copy.deepcopy(s)
    image = s["image"]
    if image.startswith(OLD_IMAGE_PREFIX):
        s["image"] = REGISTRY + "/" + image[len(OLD_IMAGE_PREFIX):].replace(OLD_TAG, ":" + TAG)
        s.pop("platform", None)  # built natively by generator/build.sh
        s.setdefault("labels", {})["eu.arrowhead.primary-source"] = "Eclipse-Arrowhead-go"
    elif name == "docker-proxy":
        s.pop("platform", None)  # arm64 image
    s["networks"] = {NETWORKS[k]: v for k, v in s["networks"].items()}
    for p in s.get("ports", []):
        p["published"] = host_port(p["published"])
    volumes, own_secrets = [], []
    for v in s.get("volumes", []):
        v = dict(v)
        if v["type"] == "volume":
            src = v["source"]
            v["source"] = src[len(OLD_PROJECT) + 1:] if src.startswith(OLD_PROJECT + "_") else f"{name}-log"
        elif v["target"].startswith("/peer-crl/"):
            continue  # v5.3.0: no federation, no peer clouds' CRLs
        else:
            v["source"] = bind_source(v["source"])
            key = pathlib.PurePosixPath(v["source"]).name
            if v["source"].startswith("./secrets/") and key in SECRET_BINDS:
                own_secrets.append({"source": key, "target": pathlib.PurePosixPath(v["target"]).name})
                secrets.add(key)
                continue
            # as in the 5.2 cloud: read-only except CertificateAuthority's /crl (it publishes the CRL there)
            v["read_only"] = bool(v.get("read_only"))
            v["bind"] = {"create_host_path": False}
        volumes.append(v)
    s["volumes"] = volumes
    if own_secrets:
        s["secrets"] = own_secrets
    env = s.get("environment") or {}
    if name in ("gatekeeper", "gatetunnel"):
        # v5.3.0: no federation (runtime-go federationEnabled=false); no relay, neighbours, peers or peer CRLs
        for k in ("RELAY_HOST", "RELAY_PORT", "RELAY_CRL_FILES", "NEIGHBOR_CLOUDS", "FEDERATION_PEER_ORGANIZATIONS",
                  "FEDERATION_FOREIGN_TARGETS", "FEDERATION_PROFILE"):
            env.pop(k, None)
    if name == "random-data-producer":
        env["INTERCLOUD_ENABLED"] = "false"
    if name == "docker-proxy":
        env["COMPOSE_PROJECT_NAME"] = PROJECT
    if name == "serviceregistry":
        s["healthcheck"] = {"test": ["CMD", "/usr/local/bin/ah-probe", "127.0.0.1:8443"], "interval": "30000ms",
                            "timeout": "4000ms", "start_period": "60000ms", "start_interval": "2000ms", "retries": 3}
    return s


def console(secrets: set[str]) -> dict:
    secrets.update({"AH_PW_LCM", "CONSOLE_PASSWORD_HASH"})
    hardening = {"user": "65532:65532", "read_only": True, "cap_drop": ["ALL"], "security_opt": ["no-new-privileges:true"],
                 "restart": "unless-stopped"}
    lcm = {
        "image": f"{REGISTRY}/ah5-localcloudmanager-go:{TAG}",
        # J7/H1 adapter around the unchanged program (generator/console/launcher)
        "entrypoint": ["/usr/local/bin/ah-lcm-launcher"],
        **hardening, "mem_limit": 134217728, "pids_limit": 128,
        "tmpfs": ["/tmp:rw,nosuid,nodev,mode=1777,size=8m"],
        "labels": {"eu.arrowhead.primary-source": "Eclipse-Arrowhead-go"},
        "environment": {
            "SYSTEM_NAME": "LocalCloudManager", "LOCAL_CLOUD": "GoCloud", "ORGANIZATION": "Company",
            "SERVER_PORT": "8480", "DOMAIN_NAME": "localcloudmanager",
            "TLS_SERVER_CERT": "/certs/local-cloud-manager.crt", "TLS_SERVER_KEY": "/certs/local-cloud-manager.key",
            "TLS_CA_CERT": "/certs/ca.crt", "TLS_CRL_FILE": "/crl/ca.crl", "DATA_FILE": "/state/localcloudmanager.json",
            "AUTHENTICATION_URL": "https://authentication:8444", "SERVICE_REGISTRY_URL": "https://serviceregistry:8443",
            "DATAMANAGER_URL": "https://datamanager:8461",
            "SIMPLE_ORCHESTRATION_URL": "https://serviceorchestration-simple:8442",
            "SYSMONITOR_URL": "https://sysmonitor:8475", "PLANT_DESCRIPTION_ENGINE_URL": "https://plantdescriptionengine:8432",
            # orchestration policy editor (ConsumerAuthorization); its default is plain HTTP, refused in secure mode
            "AUTHORIZATION_URL": "https://consumerauthorization:8445",
            "CONSOLE_ALLOWED_HOSTS": CONSOLE_HOST, "COMPOSE_PROJECT_NAME": PROJECT,
            "SECRET_ENV": "AUTHENTICATION_PASSWORD,CONSOLE_PASSWORD_HASH",
            "AUTHENTICATION_PASSWORD_FILE": "/run/secrets/identity-password",
            "CONSOLE_PASSWORD_HASH_FILE": "/run/secrets/console-password-hash",
            "DOCKER_SOCKET": "/tmp/docker.sock", "DOCKER_PROXY_ADDR": "docker-proxy:2375",
        },
        "secrets": [{"source": "AH_PW_LCM", "target": "identity-password"},
                    {"source": "CONSOLE_PASSWORD_HASH", "target": "console-password-hash"}],
        "volumes": [
            {"type": "bind", "source": "./security/bundles/localcloudmanager", "target": "/certs", "read_only": True,
             "bind": {"create_host_path": False}},
            {"type": "bind", "source": "./security/crl", "target": "/crl", "read_only": True,
             "bind": {"create_host_path": False}},
            {"type": "volume", "source": "localcloudmanager-state", "target": "/state"},
        ],
        "networks": {"arrowhead": {"aliases": ["localcloudmanager"]}, "console": {"aliases": ["localcloudmanager"]},
                     "console-docker": {}},
        "depends_on": {"docker-proxy": {"condition": "service_healthy"}},
        "healthcheck": {"test": ["CMD", "/usr/local/bin/ah-probe", "127.0.0.1:8480"], "interval": "30000ms",
                        "timeout": "4000ms", "start_period": "60000ms", "start_interval": "2000ms", "retries": 3},
    }
    proxy = {
        "image": NGINX,
        "entrypoint": ["nginx", "-g", "daemon off;"],
        **hardening, "user": "101:101", "mem_limit": 67108864, "pids_limit": 64,
        "tmpfs": ["/tmp:rw,nosuid,nodev,mode=1777,size=16m"],
        "volumes": [
            {"type": "bind", "source": "./generator/console/proxy/nginx.conf", "target": "/etc/nginx/nginx.conf",
             "read_only": True, "bind": {"create_host_path": False}},
            {"type": "bind", "source": "./security/bundles/console-proxy", "target": "/certs", "read_only": True,
             "bind": {"create_host_path": False}},
        ],
        "networks": {"console": {}},
        "ports": [{"target": 8490, "published": CONSOLE_PORT, "protocol": "tcp", "host_ip": "127.0.0.1"}],
        "depends_on": {"localcloudmanager": {"condition": "service_healthy"}},
        "healthcheck": {"test": ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8490/proxy-health"],
                        "interval": "10000ms", "timeout": "4000ms", "start_period": "10000ms", "retries": 6},
    }
    return {"localcloudmanager": lcm, "console-proxy": proxy}


def main() -> None:
    base = json.loads((HERE / "base-compose.json").read_text())
    secrets: set[str] = set()
    services = {n: convert(n, s, secrets) for n, s in base["services"].items() if n not in DROP}
    services |= console(secrets)
    volumes = sorted({v["source"] for s in services.values() for v in s.get("volumes", []) if v["type"] == "volume"})
    out = {
        "name": PROJECT,
        "services": services,
        "networks": {
            "arrowhead": {"name": f"{PROJECT}-network"},
            # console API <-> Docker proxy only (H1); internal, no route outside
            "console-docker": {"name": f"{PROJECT}_console-docker", "internal": True},
            # console proxy <-> LocalCloudManager (J6); not internal, so the proxy can publish its loopback port
            "console": {"name": f"{PROJECT}_console"},
        },
        "volumes": {v: {"name": f"{PROJECT}_{v}"} for v in volumes},
    }
    text = yaml.safe_dump(out, sort_keys=False, width=120, default_flow_style=False)
    header = (f"# Go test cloud v5.3.0, generated by generator/generate.py on {datetime.date.today()} (do not edit; edit the"
              " generator).\n# Images: Eclipse-Arrowhead-go (generator/build.sh). Secrets only as files (J7): secrets/<KEY>,"
              " written from .env by scripts/rotate-secrets.sh.\n")
    # rotate-secrets.sh reads this block line by line: one `  KEY: { file: ./secrets/KEY }` per secret
    block = "secrets:\n" + "".join(f"  {k}: {{ file: ./secrets/{k} }}\n" for k in sorted(secrets))
    target = ROOT / "compose.yaml"
    if target.exists() and "generated by generator/generate.py" not in target.read_text():
        backup = ROOT / f"compose.yaml.before-go530-{datetime.date.today():%Y%m%d}"
        if not backup.exists():
            shutil.copy2(target, backup)
    target.write_text(header + text + block)
    target.chmod(0o600)
    print(f"{len(services)} services, {len(volumes)} volumes, {len(secrets)} secrets -> {target}")


if __name__ == "__main__":
    main()
