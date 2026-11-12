#!/usr/bin/env python3
"""Arrowhead 5.2.2 SysMonitor: selective AMQP intake of sysMonitor observations, system-owned observation history
and durable republication on sysMonitorData (MQTT)."""

import hashlib
import json
import os
import sqlite3
import ssl
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

try:
    import paho.mqtt.client as mqtt
except ImportError:  # Unit tests can exercise the pure/storage layer without Paho.
    mqtt = None
try:
    from amqp_client import EXCHANGE, AmqpConsumer, AmqpPublisher
except ImportError:  # ... and without pika.
    EXCHANGE, AmqpConsumer, AmqpPublisher = "arrowhead", None, None

SYSTEM_NAME = os.getenv("ARROWHEAD_SYSTEM_NAME", "SysMonitor")
PORT = int(os.getenv("PORT", "8475"))
HEALTH_PORT = int(os.getenv("HEALTH_PORT", "8482"))
DB_PATH = os.getenv("DB_PATH", "/data/sysmonitor.db")
LOCAL_CLOUD = os.getenv("LOCAL_CLOUD", "TestCloud")
REGISTRY_URL = os.getenv("SERVICE_REGISTRY_URL", "http://serviceregistry:8443")
ORCHESTRATOR_URL = os.getenv("ORCHESTRATOR_URL", "https://serviceorchestration-dynamic:8441")
AUTHENTICATION_URL = os.getenv("AUTHENTICATION_URL", "https://authentication:8444")
AUTHENTICATION_PASSWORD = os.getenv("AUTHENTICATION_PASSWORD", "")
AUTHORIZATION_URL = os.getenv("CONSUMER_AUTHORIZATION_URL", "https://consumerauthorization:8445")
MQTT_HOST = os.getenv("MQTT_HOST", "mqtt-broker")
MQTT_PORT = int(os.getenv("MQTT_PORT", "8883"))
# sysMonitor observations arrive over AMQP; sysMonitorData is still published over MQTT.
AMQP_HOST = os.getenv("AMQP_HOST", "amqp-broker")
AMQP_PORT = int(os.getenv("AMQP_PORT", "5671"))
AMQP_QUEUE = f"{SYSTEM_NAME}.observations"
# Providers without an explicit subscription: "all" subscribes to all their observation types, "none" to nothing.
DEFAULT_SUBSCRIPTION = os.getenv("SYSMONITOR_DEFAULT_SUBSCRIPTION", "all")
ORCHESTRATION_INTERVAL_SECONDS = int(os.getenv("ORCHESTRATION_INTERVAL_SECONDS", "30"))
CA_CERT = os.getenv("TLS_CA_CERT", "/certs/ca.crt")
CERT_FILE = os.getenv("TLS_CERT", "/certs/sysmonitor.crt")
KEY_FILE = os.getenv("TLS_KEY", "/certs/sysmonitor.key")
MAX_BODY_BYTES = 1024 * 1024
# Observations from all monitored microsystems are stored here, in SysMonitor's own database.
RETENTION_DAYS = float(os.getenv("SYSMONITOR_RETENTION_DAYS", "30"))
PRUNE_INTERVAL_SECONDS = int(os.getenv("SYSMONITOR_PRUNE_INTERVAL_SECONDS", "3600"))
MAX_QUERY_COUNT = 1000
HISTORY_SERVICE = "sysMonitorHistory"
HISTORY_BASE_PATH = "/sysmonitor/history"
INPUT_PREFIX = f"{LOCAL_CLOUD}.sysmonitor"
OUTPUT_PREFIX = f"arrowhead/{LOCAL_CLOUD}/sysmonitor/data"
SELF_MONITOR_BASE = f"{INPUT_PREFIX}.{SYSTEM_NAME}.{SYSTEM_NAME}"
SELF_OBSERVATION_TYPES = ["echo", "power", "status"]


def utc_now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def epoch(instant):
    return datetime.fromisoformat(instant.replace("Z", "+00:00")).timestamp()


def tls_context():
    context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=CA_CERT)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(CERT_FILE, KEY_FILE)
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    return context


def normalize_observation(payload, routing_key, received_at=None):
    """Validates an observation against its routing key, which the broker checked against the publisher's identity."""
    if not isinstance(payload, dict):
        raise ValueError("Monitoring payload must be a JSON object")
    parts = routing_key.split(".")
    if len(parts) != 5 or parts[:2] != [LOCAL_CLOUD, "sysmonitor"]:
        raise ValueError("Routing key does not match the sysMonitor AMQP IDD")
    provider, service_instance, topic_type = parts[2:]
    if payload.get("providerSystem", provider) != provider:
        raise ValueError("providerSystem does not match the authorized routing key")
    if payload.get("serviceInstance", service_instance) != service_instance:
        raise ValueError("serviceInstance does not match the authorized routing key")
    if str(payload.get("schemaVersion", "1.0")).split(".", 1)[0] != "1":
        raise ValueError("Unsupported observation schema major version")
    observation_type = payload.get("observationType", topic_type)
    if observation_type != topic_type:
        raise ValueError("observationType does not match the routing key")
    if "value" not in payload:
        raise ValueError("Observation value is required")
    if observation_type == "echo":
        value = payload["value"]
        if not isinstance(value, dict) or value.get("status") not in ("alive", "degraded", "failed"):
            raise ValueError("echo value requires status alive, degraded, or failed")
    if observation_type == "power":
        value = payload["value"]
        if not isinstance(value, dict) or value.get("supplyType") not in ("line", "battery", "harvesting"):
            raise ValueError("power value requires supplyType line, battery, or harvesting")
    source_time = payload.get("sourceTime")
    if not isinstance(source_time, str) or not source_time.endswith("Z"):
        raise ValueError("sourceTime must be an RFC 3339 UTC instant")
    observation_id = payload.get("observationId")
    if not observation_id:
        stable = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        observation_id = hashlib.sha256(f"{routing_key}\0{stable}".encode()).hexdigest()
    return {
        "schemaVersion": "1.0",
        "observationId": str(observation_id),
        "providerSystem": payload.get("providerSystem", provider),
        "serviceInstance": payload.get("serviceInstance", service_instance),
        "observationType": observation_type,
        "sourceTime": source_time,
        "receivedTime": received_at or utc_now(),
        "publishedTime": None,
        "value": payload["value"],
        "unit": payload.get("unit"),
        "quality": payload.get("quality", "good"),
        "pipeline": {"sysMonitor": SYSTEM_NAME, "revision": 1},
        "metadata": payload.get("metadata", {}),
    }


class Store:
    def __init__(self, path):
        self.path = path
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with self.connect() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS subscriptions (
                  provider_system TEXT PRIMARY KEY, observation_types TEXT NOT NULL,
                  enabled INTEGER NOT NULL, revision INTEGER NOT NULL, updated_at TEXT NOT NULL, updated_by TEXT
                );
                CREATE TABLE IF NOT EXISTS amqp_bindings (binding_key TEXT PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS outbox (
                  observation_id TEXT PRIMARY KEY, payload TEXT NOT NULL, mqtt_published INTEGER NOT NULL DEFAULT 0,
                  attempts INTEGER NOT NULL DEFAULT 0,
                  next_attempt REAL NOT NULL DEFAULT 0, last_error TEXT, created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS observations (
                  observation_id TEXT PRIMARY KEY, provider_system TEXT NOT NULL, service_instance TEXT NOT NULL,
                  observation_type TEXT NOT NULL, source_time TEXT NOT NULL, source_epoch REAL NOT NULL,
                  received_time TEXT NOT NULL, received_epoch REAL NOT NULL, quality TEXT, unit TEXT,
                  payload TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS observations_by_system
                  ON observations(provider_system, observation_type, source_epoch);
                CREATE INDEX IF NOT EXISTS observations_by_age ON observations(received_epoch);
                CREATE TABLE IF NOT EXISTS audit (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, actor TEXT NOT NULL,
                  operation TEXT NOT NULL, target TEXT NOT NULL, outcome TEXT NOT NULL
                );
            """)
            # The MQTT topic-filter policies of the earlier intake no longer apply.
            db.execute("DROP TABLE IF EXISTS policies")

    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        return db

    @staticmethod
    def _subscription(row):
        item = dict(row)
        return {"providerSystem": item["provider_system"], "observationTypes": json.loads(item["observation_types"]),
                "enabled": bool(item["enabled"]), "revision": item["revision"], "updatedAt": item["updated_at"],
                "updatedBy": item["updated_by"]}

    def subscriptions(self):
        with self.connect() as db:
            return {row["provider_system"]: self._subscription(row)
                    for row in db.execute("SELECT * FROM subscriptions ORDER BY provider_system")}

    def subscription(self, provider):
        with self.connect() as db:
            row = db.execute("SELECT * FROM subscriptions WHERE provider_system=?", (provider,)).fetchone()
        return self._subscription(row) if row else None

    def put_subscription(self, provider, observation_types, enabled=True, actor=None, expected_revision=None):
        """observation_types: list of observation types, or ["*"] for all types the provider offers."""
        if not provider or "." in provider or "*" in provider or "#" in provider:
            raise ValueError("A provider system name is required")
        if (not isinstance(observation_types, list) or not observation_types
                or any(not isinstance(t, str) or not t or "." in t or "#" in t or (t == "*") != (observation_types == ["*"])
                       for t in observation_types)):
            raise ValueError('observationTypes must be ["*"] or a non-empty list of observation types')
        with self.connect() as db:
            current = db.execute("SELECT revision FROM subscriptions WHERE provider_system=?", (provider,)).fetchone()
            if expected_revision is not None and (not current or current[0] != expected_revision):
                raise RuntimeError("Subscription revision conflict")
            revision = (current[0] + 1) if current else 1
            db.execute("INSERT OR REPLACE INTO subscriptions VALUES (?,?,?,?,?,?)",
                       (provider, json.dumps(sorted(set(observation_types))), int(bool(enabled)), revision, utc_now(), actor))
        return self.subscription(provider)

    def delete_subscription(self, provider):
        with self.connect() as db:
            return bool(db.execute("DELETE FROM subscriptions WHERE provider_system=?", (provider,)).rowcount)

    def amqp_bindings(self):
        with self.connect() as db:
            return [row[0] for row in db.execute("SELECT binding_key FROM amqp_bindings")]

    def store_amqp_bindings(self, keys):
        with self.connect() as db:
            db.execute("DELETE FROM amqp_bindings")
            db.executemany("INSERT INTO amqp_bindings VALUES (?)", [(key,) for key in keys])

    def enqueue(self, observation):
        """Stores a new observation in the history and queues it for sysMonitorData, in one transaction."""
        payload = json.dumps(observation, separators=(",", ":"))
        with self.connect() as db:
            changed = db.execute(
                "INSERT OR IGNORE INTO observations VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (observation["observationId"], observation["providerSystem"], observation["serviceInstance"],
                 observation["observationType"], observation["sourceTime"], epoch(observation["sourceTime"]),
                 observation["receivedTime"], epoch(observation["receivedTime"]), observation.get("quality"),
                 observation.get("unit"), payload),
            ).rowcount
            if changed:
                db.execute("INSERT OR IGNORE INTO outbox(observation_id,payload,created_at) VALUES (?,?,?)",
                           (observation["observationId"], payload, utc_now()))
        return bool(changed)

    def pending(self, limit=50):
        with self.connect() as db:
            return [dict(row) for row in db.execute(
                "SELECT * FROM outbox WHERE mqtt_published=0 AND next_attempt<=? ORDER BY created_at LIMIT ?",
                (time.time(), limit),
            )]

    def published(self, observation_id):
        # The history keeps the observation; the outbox row is only needed until PUBACK.
        with self.connect() as db:
            db.execute("DELETE FROM outbox WHERE observation_id=?", (observation_id,))

    def failed(self, observation_id, error):
        with self.connect() as db:
            db.execute("UPDATE outbox SET last_error=?, attempts=attempts+1, next_attempt=? WHERE observation_id=?",
                       (error, time.time() + 5, observation_id))

    def counts(self):
        with self.connect() as db:
            pending = db.execute("SELECT COUNT(*) FROM outbox WHERE mqtt_published=0").fetchone()[0]
            stored = db.execute("SELECT COUNT(*) FROM observations").fetchone()[0]
        return {"pending": pending, "stored": stored}

    def prune(self, retention_days, now=None):
        cutoff = (now or time.time()) - retention_days * 86400
        with self.connect() as db:
            removed = db.execute("DELETE FROM observations WHERE received_epoch<?", (cutoff,)).rowcount
            db.execute("DELETE FROM outbox WHERE mqtt_published=1")
        return removed

    def history_systems(self):
        with self.connect() as db:
            return [{"systemName": row[0], "observationCount": row[1],
                     "firstObservationTime": row[2], "lastObservationTime": row[3]}
                    for row in db.execute(
                        "SELECT provider_system, COUNT(*), MIN(source_time), MAX(source_time) FROM observations "
                        "GROUP BY provider_system ORDER BY provider_system")]

    def history_query(self, system, types=None, start=None, end=None, count=100):
        sql, values = "SELECT payload FROM observations WHERE provider_system=?", [system]
        if types:
            sql += f" AND observation_type IN ({','.join('?' * len(types))})"; values += list(types)
        if start is not None:
            sql += " AND source_epoch>=?"; values.append(start)
        if end is not None:
            sql += " AND source_epoch<=?"; values.append(end)
        sql += " ORDER BY source_epoch DESC LIMIT ?"; values.append(count)
        with self.connect() as db:
            return [json.loads(row[0]) for row in db.execute(sql, values)]

    def history_latest(self, system):
        with self.connect() as db:
            rows = db.execute(
                "SELECT o.observation_type, o.payload FROM observations o JOIN ("
                "SELECT observation_type, MAX(source_epoch) AS latest FROM observations WHERE provider_system=? "
                "GROUP BY observation_type) m ON o.observation_type=m.observation_type AND o.source_epoch=m.latest "
                "WHERE o.provider_system=?", (system, system)).fetchall()
        return {row[0]: json.loads(row[1]) for row in rows}

    def audit(self, actor, operation, target, outcome):
        with self.connect() as db:
            db.execute("INSERT INTO audit(at,actor,operation,target,outcome) VALUES (?,?,?,?,?)",
                       (utc_now(), actor, operation, target, outcome))


class SysMonitor:
    def __init__(self, store):
        self.store = store
        self.lock = threading.Lock()
        self.mqtt_client = None
        self.mqtt_connected = False
        self.last_message_at = None
        self.last_error = None
        self.registration = {"registered": False, "instances": [], "error": None}
        self.identity_token = None
        self.identity_refresh = 0
        self.authorization_cache = {}
        self.retention = {"retentionDays": RETENTION_DAYS, "lastPrunedAt": None, "lastPruned": 0}
        self.orchestrated_providers = {}
        self.orchestration_error = None
        self.amqp = None            # intake consumer, created in connect_amqp()
        self.self_publisher = None

    def token(self):
        with self.lock:
            if self.identity_token and self.identity_refresh > time.time():
                return self.identity_token
        request = urllib.request.Request(
            f"{AUTHENTICATION_URL}/authentication/identity/login",
            data=json.dumps({"systemName": SYSTEM_NAME, "credentials": {"password": AUTHENTICATION_PASSWORD}}).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(request, context=tls_context(), timeout=8) as response:
            token = json.loads(response.read())["token"]
        with self.lock:
            self.identity_token, self.identity_refresh = token, time.time() + 240
        return token

    def authenticated_request(self, url, method="GET", payload=None, retry=True):
        headers = {"Authorization": f"Bearer IDENTITY-TOKEN//{self.token()}", "Content-Type": "application/json"}
        request = urllib.request.Request(url, data=None if payload is None else json.dumps(payload).encode(), headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, context=tls_context(), timeout=10) as response:
                body = response.read()
                return json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            # Authentication keeps one session per system: a restart or another login invalidates the cached token.
            if error.code != 401 or not retry:
                raise
            with self.lock:
                self.identity_token, self.identity_refresh = None, 0
            return self.authenticated_request(url, method, payload, retry=False)

    def authorized(self, consumer, operation):
        """Asks ConsumerAuthorization whether the consumer may use the given sysMonitorHistory operation."""
        key = (consumer, operation)
        cached = self.authorization_cache.get(key)
        if cached and cached > time.time():
            return True
        granted = self.authenticated_request(f"{AUTHORIZATION_URL}/consumerauthorization/authorization/verify", "POST", {
            "provider": SYSTEM_NAME, "consumer": consumer, "cloud": "LOCAL", "targetType": "SERVICE_DEF",
            "target": HISTORY_SERVICE, "scope": operation}) is True
        if granted:
            self.authorization_cache[key] = time.time() + 30
        return granted

    def register(self):
        try:
            def post(path, payload):
                request = urllib.request.Request(f"{REGISTRY_URL}{path}", data=json.dumps(payload).encode(),
                    headers={"Authorization": f"Bearer IDENTITY-TOKEN//{self.token()}", "Content-Type": "application/json"}, method="POST")
                # ServiceRegistry requires this system's identity token, bound to its client certificate (mutual TLS).
                with urllib.request.urlopen(request, context=tls_context(), timeout=8) as response:
                    return json.loads(response.read())
            post("/serviceregistry/system-discovery/register", {"metadata": {"role": "monitoring-collector", "security": "X.509"},
                 "version": "5.2.2", "addresses": ["sysmonitor"], "deviceName": None})
            instances = []
            monitor = post("/serviceregistry/service-discovery/register", {
                "serviceDefinitionName": "sysMonitor", "version": "1.0.0", "expiresAt": None,
                "metadata": {"contract": "SysMonitor-AMQP-IDD-5.2.2", "schemaVersion": "1.0",
                             "publisherMode": "native", "observationTypes": SELF_OBSERVATION_TYPES,
                             "delivery": "persistent, publisher-confirmed"},
                "interfaces": [{"templateName": "generic_amqps", "protocol": "amqps", "policy": "CERT_AUTH",
                    "properties": {"accessAddresses": [AMQP_HOST], "accessPort": AMQP_PORT, "exchange": EXCHANGE,
                                   "baseRoutingKey": SELF_MONITOR_BASE, "operations": SELF_OBSERVATION_TYPES}}]})
            instances.append(monitor["instanceId"])
            management = post("/serviceregistry/service-discovery/register", {
                "serviceDefinitionName": "sysMonitorManagement", "version": "1.0.0", "expiresAt": None,
                "metadata": {"contract": "SysMonitor-Management-HTTP-IDD-5.2.2", "defaultSubscription": DEFAULT_SUBSCRIPTION},
                "interfaces": [{
                    "templateName": "generic_https", "protocol": "https", "policy": "CERT_AUTH", "properties": {
                        "accessAddresses": ["sysmonitor"], "accessPort": PORT, "basePath": "/sysmonitor/management",
                        "operations": {"status": {"method": "GET", "path": "/status"},
                          "providers": {"method": "GET", "path": "/providers"},
                          "subscriptions": {"method": "GET", "path": "/subscriptions"},
                          "subscribe": {"method": "PUT", "path": "/subscriptions/{providerSystem}"},
                          "unsubscribe": {"method": "DELETE", "path": "/subscriptions/{providerSystem}"},
                          "reconcile": {"method": "POST", "path": "/reconcile"}}}}]})
            instances.append(management["instanceId"])
            history = post("/serviceregistry/service-discovery/register", {
                "serviceDefinitionName": HISTORY_SERVICE, "version": "1.0.0", "expiresAt": None,
                "metadata": {"contract": "SysMonitor-History-HTTP-IDD-5.2.2", "retentionDays": RETENTION_DAYS},
                "interfaces": [{
                    "templateName": "generic_https", "protocol": "https", "policy": "CERT_AUTH", "properties": {
                        "accessAddresses": ["sysmonitor"], "accessPort": PORT, "basePath": HISTORY_BASE_PATH,
                        "operations": {"list-systems": {"method": "GET", "path": "/systems"},
                          "query": {"method": "GET", "path": "/systems/{systemName}/observations"},
                          "latest": {"method": "GET", "path": "/systems/{systemName}/latest"}}}}]})
            instances.append(history["instanceId"])
            warning = None
            try:
                data_service = post("/serviceregistry/service-discovery/register", {
                    "serviceDefinitionName": "sysMonitorData", "version": "1.0.0", "expiresAt": None,
                    "metadata": {"contract": "SysMonitor-Data-MQTT-IDD-5.2.2", "schemaVersion": "1.0"},
                    "interfaces": [{"templateName": "generic_mqtts", "protocol": "ssl", "policy": "CERT_AUTH",
                        "properties": {"accessAddresses": [MQTT_HOST], "accessPort": MQTT_PORT,
                        "baseTopic": OUTPUT_PREFIX,
                        "operations": ["subscribe"]}}]})
                instances.append(data_service["instanceId"])
            except Exception as error:
                warning = f"MQTT interface registration unavailable: {error}"
            self.registration = {"registered": True, "instances": instances, "error": warning}
        except Exception as error:
            self.registration = {"registered": False, "instances": [], "error": str(error)}
            threading.Timer(10, self.register).start()

    def connect_mqtt(self):
        """MQTT connection for the sysMonitorData output only."""
        if mqtt is None:
            raise RuntimeError("paho-mqtt is not installed")
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=SYSTEM_NAME, protocol=mqtt.MQTTv5)
        client.tls_set(ca_certs=CA_CERT, certfile=CERT_FILE, keyfile=KEY_FILE, tls_version=ssl.PROTOCOL_TLS_CLIENT)
        client.tls_insecure_set(False)
        client.on_connect = self.on_connect
        client.on_disconnect = self.on_disconnect
        self.mqtt_client = client
        client.connect(MQTT_HOST, MQTT_PORT, 60, clean_start=mqtt.MQTT_CLEAN_START_FIRST_ONLY)
        client.loop_start()

    def connect_amqp(self):
        """AMQP intake: the durable queue SysMonitor.observations, bound to the selected provider routing keys."""
        if AmqpConsumer is None:
            raise RuntimeError("pika is not installed")
        self.amqp = AmqpConsumer(AMQP_HOST, AMQP_PORT, CA_CERT, CERT_FILE, KEY_FILE, f"{SYSTEM_NAME}-intake",
                                 AMQP_QUEUE, self.on_observation, applied=self.store.amqp_bindings(),
                                 bindings_store=self.store.store_amqp_bindings)
        self.self_publisher = AmqpPublisher(AMQP_HOST, AMQP_PORT, CA_CERT, CERT_FILE, KEY_FILE, f"{SYSTEM_NAME}-sysMonitor")
        threading.Thread(target=self.amqp.run, daemon=True, name="amqp-intake").start()

    def orchestrate_monitoring(self):
        """Finds all authorized sysMonitor providers, then applies the subscriptions to the intake bindings."""
        payload = {"serviceRequirement": {"serviceDefinition": "sysMonitor", "versions": ["1.0.0"],
                   "interfaceTemplateNames": ["generic_amqps"], "securityPolicies": ["CERT_AUTH"]},
                   "orchestrationFlags": {}}
        result = self.authenticated_request(f"{ORCHESTRATOR_URL}/serviceorchestration/orchestration/pull", "POST", payload)
        providers = {}
        for service in result.get("results", []):
            interface = next((item for item in service.get("interfaces", [])
                              if item.get("templateName") == "generic_amqps" and item.get("policy") == "CERT_AUTH"), None)
            if not interface:
                continue
            properties = interface.get("properties", {})
            base = properties.get("baseRoutingKey")
            provider = service.get("providerName") or service.get("provider", {}).get("name") or "unknown"
            # A provider may only be bound below its own name (<Cloud>.sysmonitor.<Provider>.<instance>).
            if not base or base.split(".")[:3] != [LOCAL_CLOUD, "sysmonitor", provider] or len(base.split(".")) != 4:
                continue
            types = (service.get("metadata") or {}).get("observationTypes") or properties.get("operations") or []
            providers[provider] = {
                "providerSystem": provider,
                "serviceInstanceId": service.get("serviceInstanceId"),
                "baseRoutingKey": base,
                "exchange": properties.get("exchange", EXCHANGE),
                "observationTypes": sorted(set(types)),
                "broker": (properties.get("accessAddresses") or [AMQP_HOST])[0],
                "port": properties.get("accessPort", AMQP_PORT),
                "orchestratedAt": utc_now(),
            }
        self.orchestrated_providers = providers
        self.apply_subscriptions()
        self.orchestration_error = None if providers else "Orchestration returned no authorized sysMonitor provider"
        return providers

    def selection(self, provider, subscriptions=None):
        """Observation types SysMonitor receives from a found provider, and where that choice comes from."""
        info = self.orchestrated_providers[provider]
        subscription = (subscriptions if subscriptions is not None else self.store.subscriptions()).get(provider)
        if subscription is None:
            return (["*"] if DEFAULT_SUBSCRIPTION == "all" else []), "default"
        if not subscription["enabled"]:
            return [], "subscription (disabled)"
        if subscription["observationTypes"] == ["*"]:
            return ["*"], "subscription"
        return [t for t in subscription["observationTypes"] if t in info["observationTypes"]], "subscription"

    def binding_keys(self):
        subscriptions = self.store.subscriptions()
        keys = set()
        for provider, info in self.orchestrated_providers.items():
            types, _source = self.selection(provider, subscriptions)
            keys.update(f"{info['baseRoutingKey']}.{t}" for t in types)
        return keys

    def apply_subscriptions(self):
        if self.amqp is not None:
            self.amqp.set_bindings(self.binding_keys())

    def providers_view(self):
        subscriptions = self.store.subscriptions()
        view = []
        for provider, info in sorted(self.orchestrated_providers.items()):
            types, source = self.selection(provider, subscriptions)
            selected = info["observationTypes"] if types == ["*"] else types
            view.append({**info, "subscribedTypes": selected, "selection": source,
                         "subscription": subscriptions.get(provider)})
        return view

    def subscriptions_view(self):
        found = self.orchestrated_providers
        return [{**item, "providerFound": provider in found,
                 "unknownTypes": [] if item["observationTypes"] == ["*"] or provider not in found else
                 [t for t in item["observationTypes"] if t not in found[provider]["observationTypes"]]}
                for provider, item in self.store.subscriptions().items()]

    def orchestration_loop(self):
        while True:
            started = time.monotonic()
            try:
                self.orchestrate_monitoring()
            except Exception as error:
                self.orchestration_error = str(error)
            time.sleep(max(1, ORCHESTRATION_INTERVAL_SECONDS - (time.monotonic() - started)))

    def on_connect(self, client, _userdata, _flags, reason_code, _properties):
        self.mqtt_connected = not reason_code.is_failure
        if reason_code.is_failure:
            self.last_error = f"MQTT connection failed: {reason_code}"
            return
        self.last_error = None

    def on_disconnect(self, _client, _userdata, _flags, reason_code, _properties):
        self.mqtt_connected = False
        if reason_code:
            self.last_error = f"MQTT disconnected: {reason_code}"

    def on_observation(self, routing_key, body):
        try:
            observation = normalize_observation(json.loads(body), routing_key)
            if self.store.enqueue(observation):
                self.last_message_at = utc_now()
        except Exception as error:
            self.last_error = f"Rejected observation: {error}"

    def reconcile(self):
        return self.orchestrate_monitoring()

    def deliver(self, row):
        """Republishes a stored observation on sysMonitorData; storage already happened at intake."""
        observation = json.loads(row["payload"])
        try:
            observation["publishedTime"] = utc_now()
            info = self.mqtt_client.publish(
                f"{OUTPUT_PREFIX}/{observation['observationType']}/{observation['providerSystem']}",
                json.dumps(observation, separators=(",", ":")), qos=1, retain=False)
            info.wait_for_publish(timeout=5)
            if info.rc != mqtt.MQTT_ERR_SUCCESS:
                raise RuntimeError(f"MQTT output publish failed: {info.rc}")
            self.store.published(row["observation_id"])
            self.last_error = None
        except Exception as error:
            self.last_error = str(error)
            self.store.failed(row["observation_id"], str(error))

    def outbox_loop(self):
        while True:
            if self.mqtt_connected:
                for row in self.store.pending():
                    self.deliver(row)
            time.sleep(1)

    def retention_loop(self):
        while True:
            try:
                removed = self.store.prune(RETENTION_DAYS)
                self.retention.update(lastPrunedAt=utc_now(), lastPruned=removed)
            except Exception as error:
                self.last_error = f"Retention pruning failed: {error}"
            time.sleep(PRUNE_INTERVAL_SECONDS)

    def self_monitor_loop(self):
        while True:
            if self.self_publisher is not None:
                common = {"schemaVersion": "1.0", "providerSystem": SYSTEM_NAME,
                          "serviceInstance": SYSTEM_NAME, "sourceTime": utc_now(), "quality": "good",
                          "metadata": {"publisherMode": "native", "arrowheadVersion": "5.2.2"}}
                observations = {
                    "echo": {"status": "alive" if self.amqp and self.amqp.connected else "degraded",
                             "detail": "AMQP intake connected" if self.amqp and self.amqp.connected else "AMQP intake not connected"},
                    "power": {"supplyType": "line", "state": "available"},
                    "status": {"state": "running", "providerCount": len(self.orchestrated_providers),
                               "bindingCount": len(self.amqp.applied) if self.amqp else 0,
                               **{key + "Observations": value for key, value in self.store.counts().items()}}}
                try:
                    for observation_type, value in observations.items():
                        payload = {**common, "observationType": observation_type, "value": value, "unit": "1"}
                        self.self_publisher.publish(f"{SELF_MONITOR_BASE}.{observation_type}", payload)
                except Exception as error:
                    self.last_error = f"sysMonitor self-publication failed: {error}"
            time.sleep(30)

    def intake_connected(self):
        return bool(self.amqp and self.amqp.connected)

    def status(self):
        healthy = self.mqtt_connected and self.intake_connected()
        return {"status": "running" if healthy else "degraded", "system": SYSTEM_NAME,
                "amqp": {"connected": self.intake_connected(), "broker": AMQP_HOST, "port": AMQP_PORT,
                         "exchange": EXCHANGE, "queue": AMQP_QUEUE,
                         "bindings": sorted(self.amqp.applied) if self.amqp else [],
                         "lastMessageAt": self.last_message_at,
                         "error": self.amqp.last_error if self.amqp else None},
                "mqtt": {"connected": self.mqtt_connected, "broker": MQTT_HOST, "port": MQTT_PORT,
                         "output": OUTPUT_PREFIX},
                "storage": {**self.store.counts(), **self.retention},
                "defaultSubscription": DEFAULT_SUBSCRIPTION,
                "subscriptions": len(self.store.subscriptions()), "registration": self.registration,
                "orchestration": {"intervalSeconds": ORCHESTRATION_INTERVAL_SECONDS,
                                  "providers": self.orchestrated_providers,
                                  "error": self.orchestration_error},
                "lastError": self.last_error, "certificateSecurity": "mutual X.509 TLS 1.2+"}


runtime = None


class Unauthenticated(PermissionError):
    """No valid identity token: answered with 401, so the caller logs in again."""


def verify_caller(handler):
    header = handler.headers.get("Authorization", "")
    prefix = "Bearer IDENTITY-TOKEN//"
    if not header.startswith(prefix):
        raise Unauthenticated("A valid Arrowhead identity token is required")
    result = runtime.authenticated_request(f"{AUTHENTICATION_URL}/authentication/identity/verify/{header[len(prefix):]}")
    if not result.get("verified"):
        raise Unauthenticated("Invalid or expired Arrowhead identity token")
    peer = handler.connection.getpeercert()
    common_name = next((value for group in peer.get("subject", ()) for key, value in group if key == "commonName"), "")
    if common_name != f"{result['systemName']}.{LOCAL_CLOUD}.Company.arrowhead.eu":
        raise PermissionError("X.509 identity does not match the Arrowhead identity token")
    # M1: only system (sy) and operator (op) certificates act as systems; onboarding (on) and device (de)
    # certificates of the same name are refused
    profile = next((v for group in peer.get("subject", ()) for k, v in group if k == "dnQualifier"), "")
    if profile not in ("sy", "op"):
        raise PermissionError(f"certificate profile '{profile}' may not call this service")
    return result["systemName"]


class ApiHandler(BaseHTTPRequestHandler):
    def send_json(self, status, payload, extra=None):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for name, value in (extra or {}).items(): self.send_header(name, value)
        self.end_headers(); self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > MAX_BODY_BYTES: raise ValueError("Invalid request body size")
        return json.loads(self.rfile.read(length))

    def authorize(self):
        actor = verify_caller(self)
        if actor != "LocalCloudManager": raise PermissionError("Management requires LocalCloudManager")
        return actor

    def history(self, actor, path, query):
        rest = path[len(HISTORY_BASE_PATH):]
        parts = [unquote(part) for part in rest.strip("/").split("/")]
        if parts == ["systems"]:
            operation = "list-systems"
        elif len(parts) == 3 and parts[0] == "systems" and parts[2] in ("observations", "latest"):
            operation = "query" if parts[2] == "observations" else "latest"
        else:
            return self.send_json(404, {"error": "Not found"})
        if not runtime.authorized(actor, operation):
            raise PermissionError(f"{actor} is not authorized for {HISTORY_SERVICE}.{operation}")
        if operation == "list-systems":
            return self.send_json(200, {"systems": runtime.store.history_systems(), "retentionDays": RETENTION_DAYS})
        system = parts[1]
        if operation == "latest":
            latest = runtime.store.history_latest(system)
            if not latest:
                return self.send_json(404, {"error": f"No stored observations for {system}"})
            return self.send_json(200, {"systemName": system, "latest": latest})
        types = [item for value in query.get("type", []) for item in value.split(",") if item]
        count = int(query.get("count", ["100"])[0])
        if not 1 <= count <= MAX_QUERY_COUNT:
            raise ValueError(f"count must be between 1 and {MAX_QUERY_COUNT}")
        start = epoch(query["from"][0]) if "from" in query else None
        end = epoch(query["to"][0]) if "to" in query else None
        observations = runtime.store.history_query(system, types, start, end, count)
        return self.send_json(200, {"systemName": system, "count": len(observations), "observations": observations})

    def do_GET(self):
        parsed = urlparse(self.path); path = parsed.path
        try:
            actor = verify_caller(self)
            if path.startswith(HISTORY_BASE_PATH + "/"):
                return self.history(actor, path, parse_qs(parsed.query))
            if actor != "LocalCloudManager": raise PermissionError("Management requires LocalCloudManager")
            if path == "/sysmonitor/management/status": return self.send_json(200, runtime.status())
            if path == "/sysmonitor/management/subscriptions":
                return self.send_json(200, {"defaultSubscription": DEFAULT_SUBSCRIPTION, "list": runtime.subscriptions_view()})
            if path == "/sysmonitor/management/providers":
                return self.send_json(200, {"defaultSubscription": DEFAULT_SUBSCRIPTION, "list": runtime.providers_view()})
            return self.send_json(404, {"error": "Not found"})
        except PermissionError as error: return self.send_json(401 if isinstance(error, Unauthenticated) else 403, {"error": str(error)})
        except ValueError as error: return self.send_json(400, {"error": str(error)})
        except Exception as error: return self.send_json(500, {"error": str(error)})

    SUBSCRIPTIONS = "/sysmonitor/management/subscriptions/"

    def subscription_target(self):
        path = urlparse(self.path).path
        if not path.startswith(self.SUBSCRIPTIONS) or "/" in path[len(self.SUBSCRIPTIONS):]:
            return None
        return unquote(path[len(self.SUBSCRIPTIONS):])

    def do_PUT(self):
        """subscribe: {"observationTypes": ["echo", "status"] | ["*"], "enabled": true}; If-Match: <revision>."""
        try:
            actor = self.authorize()
            provider = self.subscription_target()
            if not provider: return self.send_json(404, {"error": "Not found"})
            payload = self.read_json()
            expected = int(self.headers["If-Match"]) if self.headers.get("If-Match") else None
            subscription = runtime.store.put_subscription(provider, payload.get("observationTypes", ["*"]),
                                                          payload.get("enabled", True), actor, expected)
            runtime.store.audit(actor, "subscribe", provider, json.dumps(subscription["observationTypes"]))
            runtime.apply_subscriptions()
            return self.send_json(200, subscription, {"ETag": str(subscription["revision"])})
        except RuntimeError as error: return self.send_json(409, {"error": str(error)})
        except (ValueError, KeyError, json.JSONDecodeError) as error: return self.send_json(400, {"error": str(error)})
        except PermissionError as error: return self.send_json(401 if isinstance(error, Unauthenticated) else 403, {"error": str(error)})

    def do_DELETE(self):
        """unsubscribe: removes the subscription; the provider falls back to the default subscription."""
        try:
            actor = self.authorize()
            provider = self.subscription_target()
            if not provider: return self.send_json(404, {"error": "Not found"})
            if not runtime.store.delete_subscription(provider): return self.send_json(404, {"error": "Unknown subscription"})
            runtime.store.audit(actor, "unsubscribe", provider, "accepted"); runtime.apply_subscriptions()
            self.send_response(204); self.end_headers()
        except PermissionError as error: return self.send_json(401 if isinstance(error, Unauthenticated) else 403, {"error": str(error)})

    def do_POST(self):
        try:
            actor = self.authorize()
            if urlparse(self.path).path != "/sysmonitor/management/reconcile": return self.send_json(404, {"error": "Not found"})
            runtime.reconcile(); runtime.store.audit(actor, "POST", "reconcile", "accepted")
            return self.send_json(202, {"jobId": f"reconcile-{int(time.time())}"})
        except PermissionError as error: return self.send_json(401 if isinstance(error, Unauthenticated) else 403, {"error": str(error)})
        except Exception as error: return self.send_json(502, {"error": str(error)})

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}", flush=True)


class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health": self.send_response(404); self.end_headers(); return
        body = json.dumps(runtime.status(), separators=(",", ":")).encode()
        self.send_response(200 if runtime.mqtt_connected and runtime.intake_connected() else 503)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *_args): pass


class TLSHTTPServer(ThreadingHTTPServer):
    """mTLS server whose TLS handshake runs in the per-connection thread, not in accept()."""
    request_queue_size = 64
    daemon_threads = True

    def __init__(self, address, handler, context):
        self.context = context
        super().__init__(address, handler)

    def get_request(self):
        sock, address = self.socket.accept()
        return self.context.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), address

    def finish_request(self, request, client_address):
        request.settimeout(15)
        request.do_handshake()
        super().finish_request(request, client_address)


def main():
    global runtime
    runtime = SysMonitor(Store(DB_PATH))
    threading.Thread(target=runtime.register, daemon=True).start()
    threading.Thread(target=runtime.outbox_loop, daemon=True).start()
    threading.Thread(target=runtime.retention_loop, daemon=True).start()
    health = ThreadingHTTPServer(("0.0.0.0", HEALTH_PORT), HealthHandler)
    threading.Thread(target=health.serve_forever, daemon=True).start()
    runtime.connect_mqtt()
    runtime.connect_amqp()
    threading.Thread(target=runtime.self_monitor_loop, daemon=True).start()
    threading.Thread(target=runtime.orchestration_loop, daemon=True).start()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(CERT_FILE, KEY_FILE); context.load_verify_locations(CA_CERT)
    context.verify_mode = ssl.CERT_REQUIRED
    server = TLSHTTPServer(("0.0.0.0", PORT), ApiHandler, context)
    print(f"SysMonitor management API listening with mTLS on {PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
