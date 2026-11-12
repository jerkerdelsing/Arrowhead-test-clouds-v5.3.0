#!/usr/bin/env python3
"""X.509 authenticated Arrowhead random-number producer."""

import json
import os
import secrets
import ssl
import threading
import time
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    from amqp_client import EXCHANGE, AmqpPublisher
except ImportError:  # Unit tests can exercise the producer without pika.
    EXCHANGE, AmqpPublisher = "arrowhead", None

def secret_env(name, default=""):
    """NAME, else the content of the file named by NAME_FILE (Compose secrets, security finding J7)."""
    value = os.getenv(name)
    if value is not None:
        return value
    path = os.getenv(f"{name}_FILE")
    if not path:
        return default
    with open(path, encoding="utf-8") as handle:
        return handle.read().rstrip("\r\n")


SYSTEM_NAME = os.getenv("ARROWHEAD_SYSTEM_NAME", "RandomDataProducer")
REGISTRY_URL = os.getenv("SERVICE_REGISTRY_URL", "http://serviceregistry:8443")
ORCHESTRATOR_URL = os.getenv("ORCHESTRATOR_URL", "http://serviceorchestration-dynamic:8441")
AUTHENTICATION_URL = os.getenv("AUTHENTICATION_URL", "https://authentication:8444")
AUTHENTICATION_PASSWORD = secret_env("AUTHENTICATION_PASSWORD")
INTERVAL_SECONDS = int(os.getenv("PUBLISH_INTERVAL_SECONDS", "30"))
PORT = int(os.getenv("PORT", "8500"))
CA_CERT = os.getenv("TLS_CA_CERT", "/certs/ca.crt")
CLIENT_CERT = os.getenv("TLS_CLIENT_CERT", "/certs/random-data-producer.crt")
CLIENT_KEY = os.getenv("TLS_CLIENT_KEY", "/certs/random-data-producer.key")
AMQP_HOST = os.getenv("AMQP_HOST", "amqp-broker")
AMQP_PORT = int(os.getenv("AMQP_PORT", "5671"))
monitor_lock = threading.Lock()
monitor_publisher = None
LOCAL_CLOUD = os.getenv("LOCAL_CLOUD", "TestCloud")
SYSMONITOR_ROUTING_KEY = f"{LOCAL_CLOUD}.sysmonitor.{SYSTEM_NAME}.randomNumberProducer"
# Inter-cloud publishing: orchestrated with ONLY_INTERCLOUD to the DataManager of a neighbour cloud, through the
# local GateTunnel; stored there below RandomDataProducer/randomNumberProducerFrom<LocalCloud>.
INTERCLOUD_ENABLED = os.getenv("INTERCLOUD_ENABLED", "false").lower() == "true"
INTERCLOUD_SERVICE_NAME = os.getenv("INTERCLOUD_SERVICE_NAME", f"randomNumberProducerFrom{LOCAL_CLOUD}")

state_lock = threading.Lock()
state = {
    "status": "starting",
    "lastValue": None,
    "lastPublishedAt": None,
    "publishedCount": 0,
    "lastError": None,
    "orchestration": {"provider": None, "serviceInstanceId": None, "endpoint": None, "resolvedAt": None},
    "registration": {"registered": False, "instance": None, "error": None},
    "interCloud": {"enabled": INTERCLOUD_ENABLED, "status": "starting" if INTERCLOUD_ENABLED else "disabled",
                   "providerCloud": None, "provider": None, "endpoint": None, "lastValue": None,
                   "lastPublishedAt": None, "publishedCount": 0, "lastError": None},
}
identity_lock = threading.Lock()
identity_token = {"value": None, "refreshAt": 0}


def random_value():
    return secrets.randbelow(101)


def tls_context():
    context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=CA_CERT)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(CLIENT_CERT, CLIENT_KEY)
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    return context


def get_identity_token():
    with identity_lock:
        if identity_token["value"] and identity_token["refreshAt"] > time.time():
            return identity_token["value"]
        payload = {"systemName": SYSTEM_NAME, "credentials": {"password": AUTHENTICATION_PASSWORD}}
        request = urllib.request.Request(
            f"{AUTHENTICATION_URL}/authentication/identity/login",
            data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(request, context=tls_context(), timeout=5) as response:
            result = json.loads(response.read())
        identity_token.update({"value": result["token"], "refreshAt": time.time() + 240})
        return identity_token["value"]


def authorization_header():
    return {"Authorization": f"Bearer IDENTITY-TOKEN//{get_identity_token()}"}


def registry_request(path, payload):
    request = urllib.request.Request(
        f"{REGISTRY_URL}{path}",
        data=json.dumps(payload).encode(),
        headers={**authorization_header(), "Content-Type": "application/json"},
        method="POST",
    )
    # ServiceRegistry requires this system's identity token, bound to its client certificate (mutual TLS).
    with urllib.request.urlopen(request, context=tls_context(), timeout=5) as response:
        body = response.read()
        return json.loads(body) if body else None


def register():
    try:
        registry_request("/serviceregistry/system-discovery/register", {
            "metadata": {"role": "random-data-producer", "authentication": "X.509/mTLS"},
            "version": "1.0.0",
            "addresses": ["random-data-producer"],
            "deviceName": None,
        })
        result = registry_request("/serviceregistry/service-discovery/register", {
            "serviceDefinitionName": "randomNumberProducer",
            "version": "1.0.0",
            "expiresAt": None,
            "metadata": {"range": "0..100", "intervalSeconds": INTERVAL_SECONDS, "transportSecurity": "mutualTLS"},
            "interfaces": [{
                "templateName": "generic_https",
                "protocol": "https",
                "policy": "CERT_AUTH",
                "properties": {
                    "accessAddresses": ["random-data-producer"],
                    "accessPort": PORT,
                    "basePath": "/random-data-producer",
                    "operations": {"latest": {"method": "GET", "path": "/latest"}},
                },
            }],
        })
        registry_request("/serviceregistry/service-discovery/register", {
            "serviceDefinitionName": "sysMonitor", "version": "1.0.0", "expiresAt": None,
            "metadata": {"contract": "SysMonitor-AMQP-IDD-5.2.2", "schemaVersion": "1.0",
                         "publisherMode": "native", "observationTypes": ["echo", "power"]},
            "interfaces": [{"templateName": "generic_amqps", "protocol": "amqps", "policy": "CERT_AUTH",
                "properties": {"accessAddresses": [AMQP_HOST], "accessPort": AMQP_PORT, "exchange": EXCHANGE,
                    "baseRoutingKey": SYSMONITOR_ROUTING_KEY, "operations": ["echo", "power"]}}],
        })
        with state_lock:
            state["registration"] = {"registered": True, "instance": result["instanceId"], "error": None}
        print(f"Registered {result['instanceId']}", flush=True)
    except Exception as error:
        with state_lock:
            state["registration"] = {"registered": False, "instance": None, "error": str(error)}
        print(f"Registration failed: {error}", flush=True)
        timer = threading.Timer(10, register)
        timer.daemon = True
        timer.start()


DATA_SERVICE_NAME = "randomNumberProducer"


def data_path(template, system_name=SYSTEM_NAME, service_name=DATA_SERVICE_NAME):
    return template.replace("{systemName}", system_name).replace("{serviceName}", service_name)


def orchestrate_historian(flags=None, service_name=DATA_SERVICE_NAME):
    payload = {
        "serviceRequirement": {
            "serviceDefinition": "dataHistorian",
            "operations": ["put-data"],
            "versions": ["1.0.0"],
            "interfaceTemplateNames": ["generic_https"],
            "securityPolicies": ["CERT_AUTH"],
        },
        "orchestrationFlags": flags or {},
    }
    request = urllib.request.Request(
        f"{ORCHESTRATOR_URL}/serviceorchestration/orchestration/pull",
        data=json.dumps(payload).encode(),
        headers={**authorization_header(), "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, context=tls_context(), timeout=10) as response:
        result = json.loads(response.read())
    if not result.get("results"):
        raise RuntimeError("Orchestration returned no authorized dataHistorian provider")
    selected = result["results"][0]
    interface = next((item for item in selected.get("interfaces", [])
                      if item.get("protocol") == "https" and item.get("policy") == "CERT_AUTH"), None)
    if not interface:
        raise RuntimeError("Orchestration result has no HTTPS/CERT_AUTH interface")
    properties = interface.get("properties", {})
    operation = properties.get("operations", {}).get("put-data")
    if not operation or operation.get("method") != "PUT":
        raise RuntimeError("Orchestrated dataHistorian does not advertise a PUT put-data operation")
    addresses = properties.get("accessAddresses", [])
    if not addresses:
        raise RuntimeError("Orchestration result has no access address")
    endpoint = f"https://{addresses[0]}:{int(properties['accessPort'])}{properties.get('basePath', '')}{data_path(operation['path'], service_name=service_name)}"
    if flags:
        return endpoint, selected
    orchestration = {
        "provider": selected.get("providerName"),
        "serviceInstanceId": selected.get("serviceInstanceId"),
        "endpoint": endpoint,
        "resolvedAt": time.time(),
    }
    with state_lock:
        state["orchestration"] = orchestration
    return endpoint


def publish_once(context=None):
    endpoint = orchestrate_historian()
    value = random_value()
    now = time.time()
    payload = [{
        "bn": "urn:arrowhead:random-data-producer:",
        "bt": now,
        "n": "random-number",
        "u": "1",
        "v": value,
    }]
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", **authorization_header()},
        method="PUT",
    )
    with urllib.request.urlopen(request, context=context or tls_context(), timeout=10):
        pass
    if AmqpPublisher is not None:
        monitoring = {
            "schemaVersion": "1.0",
            "observationId": f"rdp-{int(now * 1000)}",
            "providerSystem": SYSTEM_NAME,
            "serviceInstance": "randomNumberProducer",
            "observationType": "power",
            "sourceTime": datetime.fromtimestamp(now, timezone.utc).isoformat().replace("+00:00", "Z"),
            "sequence": state["publishedCount"] + 1,
            "value": {"supplyType": "line", "levelPercent": value},
            "unit": "%",
            "quality": "good",
            "metadata": {"source": "RandomDataProducer"},
        }
        echo = {**monitoring, "observationId": f"rdp-echo-{int(now * 1000)}",
                "observationType": "echo", "value": {"status": "alive"}, "unit": None}
        with monitor_lock:
            global monitor_publisher
            if monitor_publisher is None:
                monitor_publisher = AmqpPublisher(AMQP_HOST, AMQP_PORT, CA_CERT, CLIENT_CERT, CLIENT_KEY,
                                                  f"{SYSTEM_NAME}-sysMonitor")
            for observation in (monitoring, echo):
                monitor_publisher.publish(f"{SYSMONITOR_ROUTING_KEY}.{observation['observationType']}",
                                          observation, observation["observationId"])
    with state_lock:
        state.update({
            "status": "running",
            "lastValue": value,
            "lastPublishedAt": now,
            "publishedCount": state["publishedCount"] + 1,
            "lastError": None,
        })
    print(f"Published random-number={value} to DataManager dataHistorian", flush=True)
    return value


def intercloud_publish_once(context, cached):
    """Publishes one value to the neighbour cloud's DataManager; re-orchestrates when the session fails."""
    if not cached.get("endpoint"):
        endpoint, selected = orchestrate_historian({"ONLY_INTERCLOUD": True}, INTERCLOUD_SERVICE_NAME)
        cached.update(endpoint=endpoint, provider=selected.get("providerName"), cloud=selected.get("cloudIdentitifer"))
    value, now = random_value(), time.time()
    payload = [{"bn": f"urn:arrowhead:{LOCAL_CLOUD}:random-data-producer:", "bt": now, "n": "random-number", "u": "1", "v": value}]
    request = urllib.request.Request(cached["endpoint"], data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json", **authorization_header()}, method="PUT")
    try:
        with urllib.request.urlopen(request, context=context, timeout=20):
            pass
    except Exception:
        cached.clear()
        raise
    with state_lock:
        ic = state["interCloud"]
        ic.update(status="running", providerCloud=cached["cloud"], provider=cached["provider"], endpoint=cached["endpoint"],
                  lastValue=value, lastPublishedAt=now, publishedCount=ic["publishedCount"] + 1, lastError=None)
    print(f"Published random-number={value} to {cached['provider']} in {cached['cloud']} (inter-cloud)", flush=True)


def intercloud_loop():
    context, cached = tls_context(), {}
    while True:
        started = time.monotonic()
        try:
            intercloud_publish_once(context, cached)
        except Exception as error:
            with state_lock:
                state["interCloud"].update(status="degraded", lastError=str(error))
            print(f"Inter-cloud publish failed: {error}", flush=True)
        time.sleep(max(0, INTERVAL_SECONDS - (time.monotonic() - started)))


def publishing_loop():
    context = tls_context()
    while True:
        started = time.monotonic()
        try:
            publish_once(context)
        except Exception as error:
            with state_lock:
                state.update({"status": "degraded", "lastError": str(error)})
            print(f"Publish failed: {error}", flush=True)
        elapsed = time.monotonic() - started
        time.sleep(max(0, INTERVAL_SECONDS - elapsed))


class StatusHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/health", "/random-data-producer/latest"):
            return self.send_json(404, {"error": "Not found"})
        with state_lock:
            payload = dict(state)
        status = 200 if payload["status"] in ("running", "starting") else 503
        self.send_json(status, payload)

    def send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


def main():
    threading.Thread(target=register, daemon=True).start()
    threading.Thread(target=publishing_loop, daemon=True).start()
    if INTERCLOUD_ENABLED:
        threading.Thread(target=intercloud_loop, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), StatusHandler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(CLIENT_CERT, CLIENT_KEY)
    context.load_verify_locations(CA_CERT)
    context.verify_mode = ssl.CERT_REQUIRED
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"RandomDataProducer mTLS status service listening on {PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
