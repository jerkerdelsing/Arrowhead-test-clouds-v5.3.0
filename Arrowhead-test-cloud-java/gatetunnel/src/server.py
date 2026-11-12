#!/usr/bin/env python3
"""Arrowhead 5.2.2 GateTunnel, migrated from the v4.6 Gateway contracts."""

import base64
import json
import os
import secrets
import sqlite3
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import itertools

from relay_client import RelayClient, cloud_of
from session_security import (RelayIdentity, ReplayWindow, SessionSecurityError, derive_keys, expired, new_ephemeral,
                              open_sealed, operation_allowed, seal, transcript)
from sysmonitor_publisher import SysMonitorPublisher

PORT = int(os.getenv("PORT", "8453"))
HEALTH_PORT = int(os.getenv("HEALTH_PORT", "8481"))
MIN_TUNNEL_PORT = int(os.getenv("MIN_TUNNEL_PORT", "8000"))
MAX_TUNNEL_PORT = int(os.getenv("MAX_TUNNEL_PORT", "8099"))
DB_PATH = os.getenv("DB_PATH", "/data/gatetunnel.db")
REGISTRY_URL = os.getenv("SERVICE_REGISTRY_URL", "https://serviceregistry:8443")
AUTH_URL = os.getenv("AUTHENTICATION_URL", "https://authentication:8444")
SYSTEM_NAME = "GateTunnel"
LOCAL_CLOUD = os.getenv("LOCAL_CLOUD", "TestCloud")
AMQP_HOST = os.getenv("AMQP_HOST", "amqp-broker")
AMQP_PORT = int(os.getenv("AMQP_PORT", "5671"))
AUTH_PASSWORD = os.getenv("AUTHENTICATION_PASSWORD", "")
CA_CERT = os.getenv("TLS_CA_CERT", "/certs/ca.crt")
SERVER_CERT = os.getenv("TLS_SERVER_CERT", "/certs/gatetunnel.crt")
SERVER_KEY = os.getenv("TLS_SERVER_KEY", "/certs/gatetunnel.key")
MAX_BODY = 1024 * 1024
ORGANIZATION = os.getenv("ORGANIZATION", "Company")
OWN_CN = f"{SYSTEM_NAME}.{LOCAL_CLOUD}.{ORGANIZATION}.arrowhead.eu"
ADVERTISED_ADDRESS = os.getenv("ADVERTISED_ADDRESS", "gatetunnel")
INTERCLOUD_MIN_PORT = int(os.getenv("INTERCLOUD_MIN_PORT", "8200"))
INTERCLOUD_MAX_PORT = int(os.getenv("INTERCLOUD_MAX_PORT", "8299"))
# Inter-cloud relay (MQTT over mutual TLS, organization PKI)
RELAY_HOST = os.getenv("RELAY_HOST", "arrowhead-relay")
RELAY_PORT = int(os.getenv("RELAY_PORT", "8883"))
RELAY_CA_CERT = os.getenv("RELAY_CA_CERT", "/certs/org-ca.crt")
RELAY_CHAIN_CERT = os.getenv("RELAY_CHAIN_CERT", "/certs/gatetunnel-relay-chain.crt")
# The relay identity is a separate key and certificate (OU=<cloud>), so the relay can tell clouds apart by subject
RELAY_KEY = os.getenv("RELAY_KEY", "/certs/gatetunnel-relay.key")
RELAY_TIMEOUT = int(os.getenv("RELAY_TIMEOUT_SECONDS", "15"))
# Session keys are signed with the relay identity and verified against the organization CA (session_security.py)
relay_identity = RelayIdentity(RELAY_KEY, RELAY_CHAIN_CERT, RELAY_CA_CERT)


class SessionStore:
    def __init__(self, path):
        self.path = path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with self.connect() as db:
            db.execute("""CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY, queue_id TEXT UNIQUE NOT NULL, peer_name TEXT NOT NULL,
                service_definition TEXT NOT NULL, tunnel_port INTEGER UNIQUE NOT NULL,
                state TEXT NOT NULL, consumer_json TEXT NOT NULL, provider_json TEXT NOT NULL,
                consumer_cloud_json TEXT NOT NULL, provider_cloud_json TEXT NOT NULL,
                relay_json TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL)""")

    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        return db

    @staticmethod
    def serialize(row):
        return {"sessionId": row["id"], "queueId": row["queue_id"], "peerName": row["peer_name"],
                "serviceDefinition": row["service_definition"], "tunnelPort": row["tunnel_port"],
                "state": row["state"], "consumer": json.loads(row["consumer_json"]),
                "provider": json.loads(row["provider_json"]),
                "consumerCloud": json.loads(row["consumer_cloud_json"]),
                "providerCloud": json.loads(row["provider_cloud_json"]),
                "relay": json.loads(row["relay_json"]), "sessionStartedAt": row["created_at"]}

    def all(self, limit=200):
        with self.connect() as db:
            rows = db.execute("SELECT * FROM sessions ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
        return [self.serialize(row) for row in rows]

    def _port(self, db):
        used = {r[0] for r in db.execute("SELECT tunnel_port FROM sessions WHERE state != 'CLOSED'")}
        for port in range(MIN_TUNNEL_PORT, MAX_TUNNEL_PORT + 1):
            if port not in used:
                return port
        raise RuntimeError("No GateTunnel ports are available")

    def create(self, payload):
        required = ("consumer", "provider", "consumerCloud", "providerCloud", "relay", "serviceDefinition")
        missing = [key for key in required if not payload.get(key)]
        if missing:
            raise ValueError(f"Missing required connection fields: {', '.join(missing)}")
        now, session_id = time.time(), secrets.token_urlsafe(18)
        queue_id = payload.get("queueId") or f"gatetunnel.{secrets.token_hex(10)}"
        peer_name = payload.get("peerName") or f"GateTunnel-{secrets.token_hex(5)}"
        with self.connect() as db:
            port = self._port(db)
            db.execute("INSERT INTO sessions VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", (
                session_id, queue_id, peer_name, str(payload["serviceDefinition"]), port, "PROVIDER_READY",
                json.dumps(payload["consumer"]), json.dumps(payload["provider"]),
                json.dumps(payload["consumerCloud"]), json.dumps(payload["providerCloud"]),
                json.dumps(payload["relay"]), now, now))
            row = db.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone()
        return self.serialize(row)

    def connect_consumer(self, payload):
        queue_id = str(payload.get("queueId", "")).strip()
        if not queue_id:
            raise ValueError("queueId is required")
        with self.connect() as db:
            row = db.execute("SELECT * FROM sessions WHERE queue_id=? AND state != 'CLOSED'", (queue_id,)).fetchone()
            if not row:
                raise LookupError("GateTunnel session was not found")
            db.execute("UPDATE sessions SET state='ACTIVE',updated_at=? WHERE id=?", (time.time(), row["id"]))
            row = db.execute("SELECT * FROM sessions WHERE id=?", (row["id"],)).fetchone()
        return self.serialize(row)

    def close(self, session_id=None, port=None):
        with self.connect() as db:
            if session_id:
                count = db.execute("UPDATE sessions SET state='CLOSED',updated_at=? WHERE id=? AND state!='CLOSED'",
                                   (time.time(), session_id)).rowcount
            else:
                count = db.execute("UPDATE sessions SET state='CLOSED',updated_at=? WHERE tunnel_port=? AND state!='CLOSED'",
                                   (time.time(), int(port))).rowcount
        return count


store = SessionStore(DB_PATH)
identity_lock = threading.Lock()
identity = {"token": None, "refresh": 0}
registration = {"registered": False, "instances": [], "error": None}


def store_health():
    try:
        with store.connect() as db:
            db.execute("SELECT 1")
        return True, "GateTunnel store available"
    except Exception as error:
        return False, f"GateTunnel store unavailable: {error}"


monitor = SysMonitorPublisher(SYSTEM_NAME, LOCAL_CLOUD, AMQP_HOST, AMQP_PORT, CA_CERT, SERVER_CERT, SERVER_KEY,
                              health=store_health, service_count=lambda: len(registration["instances"]))


def client_context():
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
    with urllib.request.urlopen(request, context=client_context(), timeout=10) as response:
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
    result = secure_json(f"{AUTH_URL}/authentication/identity/verify/{header[len(prefix):]}", token=identity_token())
    if not result.get("verified"):
        raise PermissionError("Invalid or expired Arrowhead identity token")
    common_name = next((v for group in handler.connection.getpeercert().get("subject", ())
                        for k, v in group if k == "commonName"), "")
    if common_name != f"{result['systemName']}.{LOCAL_CLOUD}.{ORGANIZATION}.arrowhead.eu":
        raise PermissionError("X.509 identity does not match the Arrowhead identity token")
    # M1: only system (sy) and operator (op) certificates act as systems; onboarding (on) and device (de)
    # certificates of the same name are refused
    profile = next((v for group in handler.connection.getpeercert().get("subject", ()) for k, v in group if k == "dnQualifier"), "")
    if profile not in ("sy", "op"):
        raise PermissionError(f"certificate profile '{profile}' may not call this service")
    return result["systemName"]


def registry_post(path, payload):
    request = urllib.request.Request(f"{REGISTRY_URL}{path}", method="POST",
        headers={"Authorization": f"Bearer IDENTITY-TOKEN//{identity_token()}", "Content-Type": "application/json"},
        data=json.dumps(payload).encode())
    with urllib.request.urlopen(request, context=client_context(), timeout=10) as response:
        return json.loads(response.read())


def register():
    global registration
    try:
        registry_post("/serviceregistry/system-discovery/register", {
            "metadata": {"role": "secure-inter-cloud-tunnel", "replaces": "Gateway-4.6.2"},
            "version": "5.2.2", "addresses": ["gatetunnel"], "deviceName": None})
        definitions = {
            "gateTunnelConnection": {"connect-provider": {"method": "POST", "path": "/connect_provider"},
                                     "connect-consumer": {"method": "POST", "path": "/connect_consumer"},
                                     "close-sessions": {"method": "POST", "path": "/close_sessions"}},
            "gateTunnelKey": {"public-key": {"method": "GET", "path": "/publickey"}},
            "gateTunnelManagement": {"sessions": {"method": "GET", "path": "/mgmt/sessions"},
                                     "close-session": {"method": "POST", "path": "/mgmt/sessions/close"}},
        }
        instances = []
        for name, operations in definitions.items():
            result = registry_post("/serviceregistry/service-discovery/register", {
                "serviceDefinitionName": name, "version": "5.2.2", "expiresAt": None,
                "metadata": {"generation": "5", "v4GatewayCompatibility": True},
                "interfaces": [{"templateName": "generic_https", "protocol": "https", "policy": "CERT_AUTH",
                    "properties": {"accessAddresses": ["gatetunnel"], "accessPort": PORT,
                                   "basePath": "/gatetunnel", "operations": operations}}]})
            instances.append(result["instanceId"])
        native = registry_post("/serviceregistry/service-discovery/register", monitor.service_registration())
        instances.append(native["instanceId"])
        registration = {"registered": True, "instances": instances, "error": None}
        print(f"Registered {SYSTEM_NAME}: {', '.join(instances)}", flush=True)
    except Exception as error:
        registration = {"registered": False, "instances": [], "error": str(error)}
        print(f"Registration failed: {error}", flush=True)
        timer = threading.Timer(10, register)
        timer.daemon = True
        timer.start()


def public_key():
    pem = subprocess.run(["openssl", "x509", "-in", SERVER_CERT, "-pubkey", "-noout"],
                         check=True, capture_output=True).stdout
    der = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"], input=pem,
                         check=True, capture_output=True).stdout
    return base64.b64encode(der).decode()


class Handler(BaseHTTPRequestHandler):
    server_version = "ArrowheadGateTunnel/5.2.2"

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

    @staticmethod
    def normalized(path):
        if path.startswith("/gateway/") or path == "/gateway":
            return "/gatetunnel" + path[len("/gateway"):]
        return path

    def authenticate(self, management=False):
        name = caller(self)
        allowed = {"LocalCloudManager", "Sysop"} if management else {
            "Gatekeeper", "DynamicServiceOrchestration", "SimpleStoreServiceOrchestration", "LocalCloudManager"}
        if name not in allowed:
            raise PermissionError(f"{name} is not authorized for this GateTunnel operation")
        return name

    def do_GET(self):
        path = self.normalized(urlparse(self.path).path.rstrip("/"))
        try:
            if path == "/health":
                return self.send_json(200, {"status": "ok", "system": SYSTEM_NAME, "version": "5.2.2",
                    "x509": True, "activeSessions": len([s for s in store.all() if s["state"] != "CLOSED"]),
                    "registration": registration, "relay": relay.status(),
                    "interCloud": {"providerSessions": len(provider_sessions), "consumerSessions": len(consumer_sessions),
                                   "sessions": intercloud_session_summary()}})
            if not self.server.secure_channel:
                return self.send_json(426, {"error": "Mutual TLS is required"})
            if path in ("/gatetunnel/echo", "/gatetunnel/monitor/echo"):
                self.authenticate()
                return self.send_json(200, {"status": "ok", "system": SYSTEM_NAME, "version": "5.2.2"})
            if path == "/gatetunnel/publickey":
                self.authenticate()
                return self.send_json(200, {"algorithm": "RSA", "format": "X.509", "publicKey": public_key()})
            if path == "/gatetunnel/mgmt/sessions":
                self.authenticate(True)
                params = parse_qs(urlparse(self.path).query)
                entries = store.all(min(max(int(params.get("limit", ["200"])[0]), 1), 1000))
                return self.send_json(200, {"entries": entries, "count": len(entries)})
            return self.send_json(404, {"error": "Not found"})
        except PermissionError as error:
            return self.send_json(401, {"error": str(error)})
        except Exception as error:
            return self.send_json(500, {"error": str(error)})

    def do_POST(self):
        path = self.normalized(urlparse(self.path).path.rstrip("/"))
        try:
            if not self.server.secure_channel:
                return self.send_json(426, {"error": "Mutual TLS is required"})
            payload = self.read_json()
            if path == "/gatetunnel/intercloud/provider":
                if self.authenticate() != "Gatekeeper":
                    raise PermissionError("Only the local Gatekeeper opens inter-cloud sessions")
                return self.send_json(201, open_provider_session(payload))
            if path == "/gatetunnel/intercloud/consumer":
                if self.authenticate() != "Gatekeeper":
                    raise PermissionError("Only the local Gatekeeper opens inter-cloud sessions")
                return self.send_json(201, open_consumer_session(payload))
            if path == "/gatetunnel/connect_provider":
                self.authenticate()
                session = store.create(payload)
                return self.send_json(201, {"sessionId": session["sessionId"], "queueId": session["queueId"],
                    "peerName": session["peerName"], "serverPort": session["tunnelPort"], "state": session["state"]})
            if path == "/gatetunnel/connect_consumer":
                self.authenticate()
                session = store.connect_consumer(payload)
                return self.send_json(201, {"sessionId": session["sessionId"], "serverPort": session["tunnelPort"],
                                            "state": session["state"]})
            if path == "/gatetunnel/close_sessions":
                self.authenticate()
                ports = payload if isinstance(payload, list) else payload.get("ports", [])
                errors = []
                for port in set(ports):
                    if not store.close(port=port):
                        errors.append({"port": port, "error": "Active session not found"})
                return self.send_json(200, errors)
            if path == "/gatetunnel/mgmt/sessions/close":
                self.authenticate(True)
                if not store.close(session_id=payload.get("sessionId"), port=payload.get("tunnelPort")):
                    return self.send_json(404, {"error": "Active session not found"})
                return self.send_json(200, {"closed": True})
            return self.send_json(404, {"error": "Not found"})
        except LookupError as error:
            return self.send_json(404, {"error": str(error)})
        except (ValueError, json.JSONDecodeError) as error:
            return self.send_json(400, {"error": str(error)})
        except PermissionError as error:
            return self.send_json(401, {"error": str(error)})
        except Exception as error:
            return self.send_json(500, {"error": str(error)})

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}", flush=True)


# ================================================================================================ inter-cloud
# Provider side: sessions negotiated by the local Gatekeeper for a foreign consumer; requests arrive over the relay
# from the peer GateTunnel and are executed against the provider with this GateTunnel's certificate and token.
# Consumer side: a dedicated HTTPS listener per session for the local consumer; requests are forwarded over the relay.
intercloud_lock = threading.Lock()
provider_sessions = {}
consumer_sessions = {}


def server_context():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(SERVER_CERT, SERVER_KEY)
    context.load_verify_locations(CA_CERT)
    context.verify_mode = ssl.CERT_REQUIRED
    return context


def intercloud_session_summary():
    """Who uses which provider across clouds (no session secrets, listeners or endpoints)."""
    with intercloud_lock:
        provider = [{"side": "provider", "consumer": s["consumer"], "consumerCloud": s["consumerCloud"], "provider": s["provider"],
                     "serviceDefinition": s["serviceDefinition"], "requests": s["requests"], "createdAt": s["createdAt"]}
                    for s in provider_sessions.values()]
        consumer = [{"side": "consumer", "consumer": s["consumer"], "providerCloud": s["providerCloud"], "provider": s.get("provider"),
                     "serviceDefinition": s.get("serviceDefinition"), "requests": s["requests"], "createdAt": s["createdAt"]}
                    for s in consumer_sessions.values()]
    return provider + consumer


def key_exchange(session, role):
    """Own half of the session key exchange: ephemeral key, signature over the transcript, relay chain."""
    signature = relay_identity.sign(transcript(role, session))
    return {f"{role}Key": session[f"{role}Key"], "signature": base64.b64encode(signature).decode(),
            "certificateChain": relay_identity.chain_pem}


def open_provider_session(payload):
    for key in ("consumer", "consumerCloud", "provider", "serviceDefinition", "peer", "target"):
        if not payload.get(key):
            raise ValueError(f"{key} is required")
    if not isinstance(payload["target"].get("operations"), dict) or not payload["target"]["operations"]:
        raise ValueError("target.operations (the negotiated operations) is required")
    session_id = secrets.token_urlsafe(18)
    key = (payload["consumer"], payload["consumerCloud"], payload["provider"], payload["serviceDefinition"])
    private, public = new_ephemeral()
    now = time.time()
    session = {**payload, "sessionId": session_id, "createdAt": now, "lastUsedAt": now, "requests": 0,
               "consumerGateTunnel": payload["peer"], "providerGateTunnel": OWN_CN, "providerKey": public,
               "ephemeral": private, "keys": None, "replay": ReplayWindow()}
    exchange = key_exchange(session, "provider")
    with intercloud_lock:
        # a renegotiation supersedes the earlier session of the same consumer, cloud, provider and service
        for old in [sid for sid, s in provider_sessions.items()
                    if (s["consumer"], s["consumerCloud"], s["provider"], s["serviceDefinition"]) == key]:
            del provider_sessions[old]
        provider_sessions[session_id] = session
    return {"sessionId": session_id, "keyExchange": exchange}


def open_consumer_session(payload):
    for key in ("sessionId", "consumer", "providerCloud", "peer", "provider", "serviceDefinition", "keyExchange"):
        if not payload.get(key):
            raise ValueError(f"{key} is required")
    exchange = payload["keyExchange"]
    now = time.time()
    payload = {**{k: v for k, v in payload.items() if k != "keyExchange"},
               "consumerCloud": f"{LOCAL_CLOUD}|{ORGANIZATION}", "consumerGateTunnel": OWN_CN,
               "providerGateTunnel": payload["peer"], "providerKey": exchange.get("providerKey"),
               "createdAt": now, "lastUsedAt": now}
    # the provider GateTunnel's signed ephemeral key, verified against the organization CA (M3)
    relay_identity.verify_peer(exchange.get("certificateChain"), payload["peer"], exchange.get("signature"),
                               transcript("provider", payload))
    private, public = new_ephemeral()
    payload["consumerKey"] = public
    payload["ownExchange"] = key_exchange(payload, "consumer")
    payload["keys"] = derive_keys(private, payload["providerKey"], payload["sessionId"])
    payload["sequence"] = itertools.count(1)
    key = (payload["consumer"], payload["providerCloud"], payload.get("provider"), payload.get("serviceDefinition"))
    with intercloud_lock:
        # a renegotiation supersedes the earlier session of the same consumer, cloud, provider and service: close its listener
        for old in [sid for sid, s in consumer_sessions.items()
                    if (s["consumer"], s["providerCloud"], s.get("provider"), s.get("serviceDefinition")) == key]:
            superseded = consumer_sessions.pop(old)
            if superseded.get("listener"):
                threading.Thread(target=superseded["listener"].shutdown, daemon=True).start()
                superseded["listener"].server_close()
        used = {s["port"] for s in consumer_sessions.values()}
        port = next((p for p in range(INTERCLOUD_MIN_PORT, INTERCLOUD_MAX_PORT + 1) if p not in used), None)
        if port is None:
            raise RuntimeError("No inter-cloud tunnel ports are available")
        session = {**payload, "port": port, "requests": 0}
        consumer_sessions[payload["sessionId"]] = session
    listener = ThreadingHTTPServer(("0.0.0.0", port), TunnelHandler)
    listener.session = session
    listener.socket = server_context().wrap_socket(listener.socket, server_side=True)
    session["listener"] = listener
    threading.Thread(target=listener.serve_forever, daemon=True).start()
    print(f"Inter-cloud session {payload['sessionId']}: {payload['consumer']} -> {payload['providerCloud']} on port {port}", flush=True)
    return {"address": ADVERTISED_ADDRESS, "port": port, "sessionId": payload["sessionId"]}


class TunnelHandler(BaseHTTPRequestHandler):
    """Consumer-side tunnel endpoint of one inter-cloud session."""
    server_version = "ArrowheadGateTunnel/5.2.2"

    def _forward(self):
        session = self.server.session
        try:
            if expired(session):
                close_consumer_session(session["sessionId"], "expired")
                raise PermissionError("Inter-cloud session has expired; orchestrate again")
            consumer = caller(self)
            if consumer != session["consumer"]:
                raise PermissionError(f"{consumer} is not the consumer of this inter-cloud session")
            size = int(self.headers.get("Content-Length", "0"))
            if size > MAX_BODY:
                raise ValueError("Request body exceeds 1 MiB")
            body = self.rfile.read(size) if size else b""
            peer_cloud, _organization = cloud_of(session["peer"])
            sequence = next(session["sequence"])
            # method, path and body travel encrypted and authenticated with the session key (M3)
            envelope = seal(session["keys"]["c2p"], session["sessionId"], "c2p", sequence,
                            {"method": self.command, "path": self.path,
                             "contentType": self.headers.get("Content-Type", ""),
                             "body": base64.b64encode(body).decode()})
            reply = relay.request(peer_cloud, {"type": "http-request", "sessionId": session["sessionId"],
                                               "keyExchange": session["ownExchange"], **envelope}, RELAY_TIMEOUT)
            if reply.get("senderCN") != session["peer"]:
                raise PermissionError("Reply does not come from the negotiated peer GateTunnel")
            if "ciphertext" not in reply:
                raise PermissionError(f"Peer GateTunnel refused the request: {reply.get('error', 'no reason')}")
            reply_sequence, content = open_sealed(session["keys"]["p2c"], session["sessionId"], "p2c", reply)
            if reply_sequence != sequence:
                raise PermissionError("Reply does not belong to this request")
            session["requests"] += 1
            session["lastUsedAt"] = time.time()
            data = base64.b64decode(content.get("body") or "")
            self.send_response(int(content.get("status", 502)))
            self.send_header("Content-Type", content.get("contentType") or "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (PermissionError, SessionSecurityError) as error:
            self._error(401, str(error))
        except TimeoutError as error:
            self._error(504, str(error))
        except Exception as error:
            self._error(502, str(error))

    def _error(self, status, message):
        data = json.dumps({"error": message}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = do_DELETE = _forward

    def log_message(self, fmt, *args):
        print(f"tunnel {self.server.session['sessionId'][:8]} {self.address_string()} - {fmt % args}", flush=True)


def refuse(sender_cn, message, reason):
    """Unencrypted refusal: carries no session data, only why the request was not executed."""
    print(f"Inter-cloud request refused ({sender_cn}): {reason}", flush=True)
    relay.reply(sender_cn, message, {"error": reason})


def handle_relay(sender_cn, message):
    """Provider side: executes a request of the peer GateTunnel against the provider of the session."""
    if message.get("type") != "http-request" or not sender_cn.startswith("GateTunnel."):
        return
    with intercloud_lock:
        session = provider_sessions.get(message.get("sessionId"))
    if not session or session["peer"] != sender_cn:
        return refuse(sender_cn, message, "Unknown inter-cloud session or wrong peer")
    if expired(session):
        with intercloud_lock:
            provider_sessions.pop(session["sessionId"], None)
        return refuse(sender_cn, message, "Inter-cloud session has expired")
    try:
        exchange = message.get("keyExchange") or {}
        with intercloud_lock:
            if session["keys"] is None:
                # first request: the consumer GateTunnel's signed ephemeral key completes the key exchange (M3)
                candidate = {**session, "consumerKey": exchange.get("consumerKey")}
                relay_identity.verify_peer(exchange.get("certificateChain"), session["peer"], exchange.get("signature"),
                                           transcript("consumer", candidate))
                session["consumerKey"] = exchange["consumerKey"]
                session["keys"] = derive_keys(session.pop("ephemeral"), session["consumerKey"], session["sessionId"])
            elif exchange.get("consumerKey") != session["consumerKey"]:
                raise SessionSecurityError("key exchange differs from the established one")
        sequence, content = open_sealed(session["keys"]["c2p"], session["sessionId"], "c2p", message)
        if not session["replay"].accept(sequence):
            raise SessionSecurityError("replayed or outdated request")
    except SessionSecurityError as error:
        return refuse(sender_cn, message, str(error))

    def answer(status, data, content_type="application/json"):
        relay.reply(sender_cn, message, seal(session["keys"]["p2c"], session["sessionId"], "p2c", sequence,
                                             {"status": status, "contentType": content_type,
                                              "body": base64.b64encode(data).decode()}))

    target, method, path = session["target"], str(content.get("method", "GET")), str(content.get("path", "/"))
    try:
        allowed = operation_allowed(method, path, target.get("basePath"), target.get("operations"))
    except SessionSecurityError as error:
        return answer(400, json.dumps({"error": str(error)}).encode())
    if not allowed:
        # only the negotiated operations, on a normalized path below the provider's base path (M2)
        return answer(403, b'{"error":"Operation outside the negotiated session"}')
    request = urllib.request.Request(f"https://{target['address']}:{int(target['port'])}{path}",
        method=method, data=base64.b64decode(content.get("body") or "") or None,
        headers={"Authorization": f"Bearer IDENTITY-TOKEN//{identity_token()}",
                 "Content-Type": content.get("contentType") or "application/json",
                 "X-Arrowhead-Remote-Consumer": f"{session['consumer']}|{session['consumerCloud']}"})
    try:
        with urllib.request.urlopen(request, context=client_context(), timeout=RELAY_TIMEOUT) as response:
            status, data, content_type = response.status, response.read(), response.headers.get("Content-Type", "")
    except urllib.error.HTTPError as error:
        status, data, content_type = error.code, error.read(), error.headers.get("Content-Type", "")
    session["requests"] += 1
    session["lastUsedAt"] = time.time()
    answer(status, data, content_type)


def close_consumer_session(session_id, reason):
    with intercloud_lock:
        session = consumer_sessions.pop(session_id, None)
    if session and session.get("listener"):
        threading.Thread(target=session["listener"].shutdown, daemon=True).start()
        session["listener"].server_close()
        print(f"Inter-cloud session {session_id[:8]} closed ({reason}); port {session['port']} released", flush=True)


def session_janitor():
    """Ends sessions past their maximum age or idle time (M2): provider sessions and consumer listeners."""
    while True:
        time.sleep(60)
        with intercloud_lock:
            stale_provider = [sid for sid, s in provider_sessions.items() if expired(s)]
            for sid in stale_provider:
                del provider_sessions[sid]
            stale_consumer = [sid for sid, s in consumer_sessions.items() if expired(s)]
        for sid in stale_consumer:
            close_consumer_session(sid, "expired")
        if stale_provider:
            print(f"Expired {len(stale_provider)} provider-side inter-cloud session(s)", flush=True)


relay = RelayClient("gatetunnel", OWN_CN, RELAY_HOST, RELAY_PORT, RELAY_CA_CERT, RELAY_CHAIN_CERT, RELAY_KEY,
                    handle_relay, log=lambda m: print(m, flush=True))


def main():
    threading.Thread(target=register, daemon=True).start()
    monitor.start()
    relay.start()
    threading.Thread(target=session_janitor, daemon=True).start()
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
    print(f"GateTunnel 5.2.2 mTLS on {PORT}; control ports {MIN_TUNNEL_PORT}-{MAX_TUNNEL_PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
