#!/usr/bin/env python3
"""Arrowhead 5.2 Gatekeeper compatibility microsystem.

Preserves the Gatekeeper 4.6 GSD/ICN resource paths while using Arrowhead 5
system/service identities, service-operation registration, independent storage,
outsourced Authentication identity tokens and mandatory mutual TLS.
"""

import json
import os
import sqlite3
import ssl
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

from relay_client import RelayClient, cloud_identifier, cloud_of
from sysmonitor_publisher import SysMonitorPublisher

PORT = int(os.getenv("PORT", "8449"))
HEALTH_PORT = int(os.getenv("HEALTH_PORT", "8480"))
DB_PATH = os.getenv("DB_PATH", "/data/gatekeeper.db")
REGISTRY_URL = os.getenv("SERVICE_REGISTRY_URL", "https://serviceregistry:8443")
AUTH_URL = os.getenv("AUTHENTICATION_URL", "https://authentication:8444")
SYSTEM_NAME = os.getenv("ARROWHEAD_SYSTEM_NAME", "Gatekeeper")
LOCAL_CLOUD = os.getenv("LOCAL_CLOUD", "TestCloud")
AMQP_HOST = os.getenv("AMQP_HOST", "amqp-broker")
AMQP_PORT = int(os.getenv("AMQP_PORT", "5671"))
AUTH_PASSWORD = os.getenv("AUTHENTICATION_PASSWORD", "")
CA_CERT = os.getenv("TLS_CA_CERT", "/certs/ca.crt")
SERVER_CERT = os.getenv("TLS_SERVER_CERT", "/certs/gatekeeper.crt")
SERVER_KEY = os.getenv("TLS_SERVER_KEY", "/certs/gatekeeper.key")
MAX_BODY = 1024 * 1024
ORGANIZATION = os.getenv("ORGANIZATION", "Company")
OWN_CN = f"{SYSTEM_NAME}.{LOCAL_CLOUD}.{ORGANIZATION}.arrowhead.eu"
CONSUMER_AUTHORIZATION_URL = os.getenv("CONSUMER_AUTHORIZATION_URL", "https://consumerauthorization:8445")
GATETUNNEL_URL = os.getenv("GATETUNNEL_URL", "https://gatetunnel:8453")
# Inter-cloud relay (MQTT over mutual TLS, organization PKI)
RELAY_HOST = os.getenv("RELAY_HOST", "arrowhead-relay")
RELAY_PORT = int(os.getenv("RELAY_PORT", "8883"))
RELAY_CA_CERT = os.getenv("RELAY_CA_CERT", "/certs/org-ca.crt")
RELAY_CHAIN_CERT = os.getenv("RELAY_CHAIN_CERT", "/certs/gatekeeper-relay-chain.crt")
# The relay identity is a separate key and certificate (OU=<cloud>), so the relay can tell clouds apart by subject
RELAY_KEY = os.getenv("RELAY_KEY", "/certs/gatekeeper-relay.key")
RELAY_TIMEOUT = int(os.getenv("RELAY_TIMEOUT_SECONDS", "10"))


class Store:
    def __init__(self, path):
        self.path = path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with self.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS clouds (
                    name TEXT NOT NULL, operator TEXT NOT NULL,
                    gatekeeper_address TEXT, gatekeeper_port INTEGER,
                    metadata TEXT NOT NULL DEFAULT '{}',
                    created_at REAL NOT NULL, updated_at REAL NOT NULL,
                    PRIMARY KEY(name, operator));
                CREATE TABLE IF NOT EXISTS relays (
                    name TEXT PRIMARY KEY, address TEXT NOT NULL, port INTEGER NOT NULL,
                    type TEXT NOT NULL, secure INTEGER NOT NULL DEFAULT 1,
                    metadata TEXT NOT NULL DEFAULT '{}', created_at REAL NOT NULL);
            """)

    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        return db

    @staticmethod
    def cloud(row):
        return {"name": row["name"], "operator": row["operator"], "neighbor": True,
                "secure": True, "gatekeeperAddress": row["gatekeeper_address"],
                "gatekeeperPort": row["gatekeeper_port"], "metadata": json.loads(row["metadata"])}

    def clouds(self):
        with self.connect() as db:
            return [self.cloud(r) for r in db.execute("SELECT * FROM clouds ORDER BY operator,name")]

    def put_clouds(self, values):
        now = time.time()
        with self.connect() as db:
            for item in values:
                name, operator = str(item.get("name", "")).strip(), str(item.get("operator", "")).strip()
                if not name or not operator:
                    raise ValueError("Every cloud requires non-empty name and operator")
                db.execute("""INSERT INTO clouds(name,operator,gatekeeper_address,gatekeeper_port,metadata,created_at,updated_at)
                    VALUES(?,?,?,?,?,?,?) ON CONFLICT(name,operator) DO UPDATE SET
                    gatekeeper_address=excluded.gatekeeper_address, gatekeeper_port=excluded.gatekeeper_port,
                    metadata=excluded.metadata, updated_at=excluded.updated_at""",
                    (name, operator, item.get("gatekeeperAddress") or item.get("address"),
                     item.get("gatekeeperPort") or item.get("port"), json.dumps(item.get("metadata", {})), now, now))
        return self.clouds()

    def delete_cloud(self, operator, name):
        with self.connect() as db:
            return db.execute("DELETE FROM clouds WHERE operator=? AND name=?", (operator, name)).rowcount

    def relays(self):
        with self.connect() as db:
            return [dict(r) | {"secure": bool(r["secure"]), "metadata": json.loads(r["metadata"])}
                    for r in db.execute("SELECT * FROM relays ORDER BY name")]

    def put_relays(self, values):
        now = time.time()
        with self.connect() as db:
            for item in values:
                name, address = str(item.get("name", "")).strip(), str(item.get("address", "")).strip()
                port = int(item.get("port", 0))
                if not name or not address or not 1 <= port <= 65535:
                    raise ValueError("Every relay requires name, address and a valid port")
                db.execute("""INSERT INTO relays(name,address,port,type,secure,metadata,created_at)
                    VALUES(?,?,?,?,?,?,?) ON CONFLICT(name) DO UPDATE SET address=excluded.address,
                    port=excluded.port,type=excluded.type,secure=excluded.secure,metadata=excluded.metadata""",
                    (name, address, port, item.get("type", "GATEKEEPER_RELAY"),
                     int(bool(item.get("secure", True))), json.dumps(item.get("metadata", {})), now))
        return self.relays()


store = Store(DB_PATH)
identity_lock = threading.Lock()
identity = {"token": None, "refresh": 0}
registration = {"registered": False, "instances": [], "error": None}


def store_health():
    try:
        with store.connect() as db:
            db.execute("SELECT 1")
        return True, "Gatekeeper store available"
    except Exception as error:
        return False, f"Gatekeeper store unavailable: {error}"


monitor = SysMonitorPublisher(SYSTEM_NAME, LOCAL_CLOUD, AMQP_HOST, AMQP_PORT, CA_CERT, SERVER_CERT, SERVER_KEY,
                              health=store_health, service_count=lambda: len(registration["instances"]))


def tls_context():
    context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=CA_CERT)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(SERVER_CERT, SERVER_KEY)
    return context


def secure_json(url, method="GET", payload=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer IDENTITY-TOKEN//{token}"
    request = urllib.request.Request(url, method=method, headers=headers,
                                     data=None if payload is None else json.dumps(payload).encode())
    with urllib.request.urlopen(request, context=tls_context(), timeout=10) as response:
        body = response.read()
        return json.loads(body) if body else None


def identity_token():
    with identity_lock:
        if identity["token"] and identity["refresh"] > time.time():
            return identity["token"]
        result = secure_json(f"{AUTH_URL}/authentication/identity/login", "POST",
                             {"systemName": SYSTEM_NAME, "credentials": {"password": AUTH_PASSWORD}})
        identity.update(token=result["token"], refresh=time.time() + 240)
        return identity["token"]


def caller(handler):
    prefix = "Bearer IDENTITY-TOKEN//"
    header = handler.headers.get("Authorization", "")
    if not header.startswith(prefix):
        raise PermissionError("A valid Arrowhead identity token is required")
    result = secure_json(f"{AUTH_URL}/authentication/identity/verify/{header[len(prefix):]}",
                         token=identity_token())
    if not result.get("verified"):
        raise PermissionError("Invalid or expired Arrowhead identity token")
    cert = handler.connection.getpeercert()
    common_name = next((v for group in cert.get("subject", ()) for k, v in group if k == "commonName"), "")
    if common_name != f"{result['systemName']}.{LOCAL_CLOUD}.{ORGANIZATION}.arrowhead.eu":
        raise PermissionError("X.509 identity does not match the Arrowhead identity token")
    # M1: only system (sy) and operator (op) certificates act as systems; onboarding (on) and device (de)
    # certificates of the same name are refused
    profile = next((v for group in cert.get("subject", ()) for k, v in group if k == "dnQualifier"), "")
    if profile not in ("sy", "op"):
        raise PermissionError(f"certificate profile '{profile}' may not call this service")
    return result["systemName"]


def registry_post(path, payload):
    request = urllib.request.Request(f"{REGISTRY_URL}{path}", method="POST",
        headers={"Authorization": f"Bearer IDENTITY-TOKEN//{identity_token()}", "Content-Type": "application/json"},
        data=json.dumps(payload).encode())
    with urllib.request.urlopen(request, context=tls_context(), timeout=10) as response:
        return json.loads(response.read())


def register():
    global registration
    try:
        registry_post("/serviceregistry/system-discovery/register", {
            "metadata": {"role": "inter-cloud-gatekeeper", "sourceCompatibility": "4.6.2"},
            "version": "5.2.2", "addresses": ["gatekeeper"], "deviceName": None})
        definitions = {
            "globalServiceDiscovery": {"query": {"method": "POST", "path": "/init_gsd"},
                                       "multi-query": {"method": "POST", "path": "/init_multi_gsd"}},
            "interCloudNegotiation": {"negotiate": {"method": "POST", "path": "/init_icn"}},
            "gatekeeperManagement": {"clouds": {"method": "GET", "path": "/mgmt/clouds"},
                                     "relays": {"method": "GET", "path": "/mgmt/relays"}},
        }
        instances = []
        for name, operations in definitions.items():
            result = registry_post("/serviceregistry/service-discovery/register", {
                "serviceDefinitionName": name, "version": "5.2.2", "expiresAt": None,
                "metadata": {"generation": "5", "v4Compatibility": True},
                "interfaces": [{"templateName": "generic_https", "protocol": "https", "policy": "CERT_AUTH",
                    "properties": {"accessAddresses": ["gatekeeper"], "accessPort": PORT,
                                   "basePath": "/gatekeeper", "operations": operations}}]})
            instances.append(result["instanceId"])
        native = registry_post("/serviceregistry/service-discovery/register", monitor.service_registration())
        instances.append(native["instanceId"])
        registration = {"registered": True, "instances": instances, "error": None}
        print(f"Registered {SYSTEM_NAME}: {', '.join(instances)}", flush=True)
    except Exception as error:
        registration = {"registered": False, "instances": [], "error": str(error)}
        print(f"Registration failed: {error}", flush=True)
        threading.Timer(10, register).start()


# ================================================================================================ inter-cloud
def neighbor_clouds():
    """Names of the configured neighbour clouds of the own organization (gatekeeperManagement clouds)."""
    return [c["name"] for c in store.clouds() if c["operator"] == ORGANIZATION and c["name"] != LOCAL_CLOUD]


def local_instances(service_definition):
    """generic_https instances of a service definition in the local ServiceRegistry."""
    result = secure_json(f"{REGISTRY_URL}/serviceregistry/service-discovery/lookup", "POST",
                         {"serviceDefinitionNames": [service_definition], "interfaceTemplateNames": ["generic_https"]},
                         token=identity_token())
    return result.get("entries", []) if result else []


def is_authorized(provider, consumer, consumer_cloud, service_definition, operations):
    """Asks the local ConsumerAuthorization whether a consumer of a foreign cloud may use the service.

    The Gatekeeper is an intermediary, so it uses authorizationManagement.check-policies (granted to it by an
    MGMT policy for that operation only, scripts/configure-intercloud.sh); authorization.verify answers only the
    provider or the consumer itself."""
    checks = []
    for operation in operations or [None]:
        entry = {"provider": provider, "consumer": consumer, "cloud": consumer_cloud,
                 "targetType": "SERVICE_DEF", "target": service_definition}
        if operation:
            entry["scope"] = operation
        checks.append(entry)
    try:
        result = secure_json(f"{CONSUMER_AUTHORIZATION_URL}/consumerauthorization/authorization/mgmt/check", "POST",
                             {"list": checks}, token=identity_token())
        entries = (result or {}).get("entries", [])
        return len(entries) == len(checks) and all(e.get("granted") is True for e in entries)
    except Exception as error:
        print(f"Inter-cloud authorization check failed (deny): {error}", flush=True)
        return False


def https_interface(instance):
    return next((i for i in instance.get("interfaces", []) if i.get("templateName") == "generic_https"), None)


def handle_relay(sender_cn, message):
    """Requests of foreign Gatekeepers; the sender cloud comes from the broker-authenticated topic."""
    if not sender_cn.startswith("Gatekeeper."):
        return
    consumer_cloud = cloud_identifier(sender_cn)
    kind = message.get("type")
    if kind == "gsd-request":
        requirement = message.get("serviceRequirement", {})
        definition = requirement.get("serviceDefinition")
        operations = requirement.get("operations") or []
        results = []
        for instance in local_instances(definition) if definition else []:
            provider = instance.get("provider", {}).get("name")
            interface = https_interface(instance)
            if interface and is_authorized(provider, message.get("consumer"), consumer_cloud, definition, operations):
                results.append({"providerName": provider, "serviceDefinition": definition,
                                "version": instance.get("version"), "metadata": instance.get("metadata", {}),
                                "operations": sorted(interface.get("properties", {}).get("operations", {}).keys())})
        print(f"GSD from {consumer_cloud} for {definition}: {len(results)} authorized provider(s)", flush=True)
        relay.reply(sender_cn, message, {"cloud": f"{LOCAL_CLOUD}|{ORGANIZATION}", "results": results})
    elif kind == "icn-request":
        definition, provider = message.get("serviceDefinition"), message.get("providerName")
        consumer, operations = message.get("consumer"), message.get("operations") or []
        if not is_authorized(provider, consumer, consumer_cloud, definition, operations):
            return relay.reply(sender_cn, message, {"accepted": False, "reason": "Not authorized by the provider cloud"})
        instance = next((i for i in local_instances(definition) if i.get("provider", {}).get("name") == provider), None)
        interface = https_interface(instance) if instance else None
        if not interface:
            return relay.reply(sender_cn, message, {"accepted": False, "reason": "Provider not found"})
        props = interface.get("properties", {})
        offered = props.get("operations", {}) or {}
        # the session admits only the negotiated operations: the requested ones, or all when none were named (M2)
        if any(operation not in offered for operation in operations):
            return relay.reply(sender_cn, message, {"accepted": False, "reason": "Operation not offered by the provider"})
        negotiated = {name: offered[name] for name in (operations or offered)}
        cloud, organization = cloud_of(sender_cn)
        session = secure_json(f"{GATETUNNEL_URL}/gatetunnel/intercloud/provider", "POST", {
            "consumer": consumer, "consumerCloud": consumer_cloud, "provider": provider,
            "serviceDefinition": definition, "peer": f"GateTunnel.{cloud}.{organization}.arrowhead.eu",
            "target": {"address": props.get("accessAddresses", [None])[0], "port": props.get("accessPort"),
                       "basePath": props.get("basePath", ""), "operations": negotiated}}, token=identity_token())
        print(f"ICN from {consumer_cloud}: {consumer} -> {provider}.{definition} {sorted(negotiated)}, "
              f"session {session['sessionId']}", flush=True)
        # keyExchange: the provider GateTunnel's signed ephemeral key, passed on to the consumer GateTunnel (M3)
        relay.reply(sender_cn, message, {"accepted": True, "sessionId": session["sessionId"],
                                         "providerName": provider, "serviceDefinition": definition,
                                         "version": instance.get("version"), "metadata": instance.get("metadata", {}),
                                         "basePath": props.get("basePath", ""), "operations": negotiated,
                                         "keyExchange": session["keyExchange"]})


def init_gsd(payload):
    requirement = payload.get("serviceRequirement") or payload.get("requestedService") or {}
    if not requirement.get("serviceDefinition"):
        raise ValueError("serviceRequirement.serviceDefinition is required")
    targets = payload.get("targetClouds") or neighbor_clouds()
    results, unsuccessful = [], 0
    for cloud in targets:
        name = cloud.split("|")[0] if isinstance(cloud, str) else cloud.get("name")
        try:
            reply = relay.request(name, {"type": "gsd-request", "consumer": payload.get("consumerSystem"),
                                         "serviceRequirement": requirement}, RELAY_TIMEOUT)
            results.extend({**item, "cloud": reply.get("cloud")} for item in reply.get("results", []))
        except Exception as error:
            unsuccessful += 1
            print(f"GSD to {name} failed: {error}", flush=True)
    return {"results": results, "unsuccessfulRequests": unsuccessful, "queriedClouds": len(targets)}


def init_icn(payload):
    target = payload.get("targetCloud") or payload.get("providerCloud")
    if not target or not payload.get("providerName") or not payload.get("serviceDefinition"):
        raise ValueError("targetCloud, providerName and serviceDefinition are required")
    cloud = target.split("|")[0] if isinstance(target, str) else target.get("name")
    reply = relay.request(cloud, {"type": "icn-request", "consumer": payload.get("consumerSystem"),
                                  "providerName": payload["providerName"], "serviceDefinition": payload["serviceDefinition"],
                                  "operations": payload.get("operations") or []}, RELAY_TIMEOUT)
    if not reply.get("accepted"):
        return {"negotiated": False, "targetCloud": target, "reason": reply.get("reason")}
    organization = reply["senderCN"].split(".")[2]
    tunnel = secure_json(f"{GATETUNNEL_URL}/gatetunnel/intercloud/consumer", "POST", {
        "sessionId": reply["sessionId"], "consumer": payload.get("consumerSystem"), "providerCloud": f"{cloud}|{organization}",
        "provider": reply["providerName"], "serviceDefinition": reply["serviceDefinition"],
        "peer": f"GateTunnel.{cloud}.{organization}.arrowhead.eu", "keyExchange": reply.get("keyExchange")},
        token=identity_token())
    return {"negotiated": True, "providerCloud": f"{cloud}|{organization}", "providerName": reply["providerName"],
            "serviceDefinition": reply["serviceDefinition"], "version": reply.get("version"),
            "metadata": reply.get("metadata", {}), "sessionId": reply["sessionId"],
            "interface": {"templateName": "generic_https", "protocol": "https", "policy": "CERT_AUTH",
                          "properties": {"accessAddresses": [tunnel["address"]], "accessPort": tunnel["port"],
                                         "basePath": reply.get("basePath", ""), "operations": reply.get("operations", {})}}}


relay = RelayClient("gatekeeper", OWN_CN, RELAY_HOST, RELAY_PORT, RELAY_CA_CERT, RELAY_CHAIN_CERT, RELAY_KEY,
                    handle_relay, log=lambda m: print(m, flush=True))


class Handler(BaseHTTPRequestHandler):
    server_version = "ArrowheadGatekeeper/5.2.2"

    def send_json(self, status, value):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        size = int(self.headers.get("Content-Length", "0"))
        if not 0 < size <= MAX_BODY:
            raise ValueError("Request body is empty or exceeds 1 MiB")
        return json.loads(self.rfile.read(size))

    def authenticate(self, management=False):
        name = caller(self)
        allowed = {"LocalCloudManager", "Sysop"} if management else {
            "DynamicServiceOrchestration", "SimpleStoreServiceOrchestration", "LocalCloudManager", "Gatekeeper"}
        if name not in allowed:
            raise PermissionError(f"{name} is not authorized for this Gatekeeper operation")
        return name

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/")
        try:
            if path == "/health":
                return self.send_json(200, {"status": "ok", "system": SYSTEM_NAME,
                    "version": "5.2.2", "x509": True, "registration": registration, "relay": relay.status()})
            if not self.server.secure_channel:
                return self.send_json(426, {"error": "Mutual TLS is required"})
            if path in ("/gatekeeper/echo", "/gatekeeper/monitor/echo"):
                self.authenticate()
                return self.send_json(200, {"status": "ok", "system": SYSTEM_NAME, "version": "5.2.2"})
            if path == "/gatekeeper/mgmt/clouds":
                self.authenticate(True)
                entries = store.clouds()
                return self.send_json(200, {"entries": entries, "count": len(entries)})
            if path == "/gatekeeper/mgmt/relays":
                self.authenticate(True)
                entries = store.relays()
                return self.send_json(200, {"entries": entries, "count": len(entries)})
            return self.send_json(404, {"error": "Not found"})
        except PermissionError as error:
            return self.send_json(401, {"error": str(error)})
        except Exception as error:
            return self.send_json(500, {"error": str(error)})

    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/")
        try:
            if not self.server.secure_channel:
                return self.send_json(426, {"error": "Mutual TLS is required"})
            payload = self.read_json()
            if path == "/gatekeeper/mgmt/clouds":
                self.authenticate(True)
                values = payload if isinstance(payload, list) else payload.get("list", [payload])
                entries = store.put_clouds(values)
                return self.send_json(201, {"entries": entries, "count": len(entries)})
            if path == "/gatekeeper/mgmt/relays":
                self.authenticate(True)
                values = payload if isinstance(payload, list) else payload.get("list", [payload])
                entries = store.put_relays(values)
                return self.send_json(201, {"entries": entries, "count": len(entries)})
            if path in ("/gatekeeper/init_gsd", "/gatekeeper/init_multi_gsd"):
                requester = self.authenticate()
                payload.setdefault("consumerSystem", requester)
                return self.send_json(200, init_gsd(payload))
            if path == "/gatekeeper/init_icn":
                requester = self.authenticate()
                payload.setdefault("consumerSystem", requester)
                return self.send_json(200, init_icn(payload))
            return self.send_json(404, {"error": "Not found"})
        except (ValueError, json.JSONDecodeError) as error:
            return self.send_json(400, {"error": str(error)})
        except PermissionError as error:
            return self.send_json(401, {"error": str(error)})
        except Exception as error:
            return self.send_json(500, {"error": str(error)})

    def do_DELETE(self):
        path = urlparse(self.path).path.rstrip("/")
        try:
            self.authenticate(True)
            prefix = "/gatekeeper/mgmt/clouds/"
            if path.startswith(prefix):
                operator, name = [unquote(v) for v in path[len(prefix):].split("/", 1)]
                if not store.delete_cloud(operator, name):
                    return self.send_json(404, {"error": "Cloud not found"})
                return self.send_json(200, {"removed": True})
            return self.send_json(404, {"error": "Not found"})
        except (ValueError, PermissionError) as error:
            return self.send_json(401 if isinstance(error, PermissionError) else 400, {"error": str(error)})

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}", flush=True)


def main():
    threading.Thread(target=register, daemon=True).start()
    monitor.start()
    relay.start()
    health = ThreadingHTTPServer(("0.0.0.0", HEALTH_PORT), Handler)
    health.secure_channel = False
    threading.Thread(target=health.serve_forever, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.secure_channel = True
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(SERVER_CERT, SERVER_KEY)
    context.load_verify_locations(CA_CERT)
    context.verify_mode = ssl.CERT_REQUIRED
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"Gatekeeper 5.2.2 mTLS on {PORT}; health on {HEALTH_PORT}; database {DB_PATH}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
