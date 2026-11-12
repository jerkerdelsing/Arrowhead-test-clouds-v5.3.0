"""Arrowhead inter-cloud relay client (MQTT over mutual TLS) shared by Gatekeeper and GateTunnel.

Topic layout on the relay broker:

    arrowhead/relay/<targetCloud>/<role>/in/<senderCN>/<messageId>

A client subscribes to its own cloud's inbox of its role and writes into another cloud's inbox only below
its own certificate CN (enforced by the broker ACL). The sender identity and its cloud are therefore taken
from the topic, which the broker has authenticated, and never from the message body.
"""

import json
import secrets
import ssl
import threading
import time

import paho.mqtt.client as mqtt


def cloud_of(common_name):
    """'Gatekeeper.GoCloud.Company.arrowhead.eu' -> ('GoCloud', 'Company')."""
    parts = common_name.split(".")
    if len(parts) != 5 or parts[3] != "arrowhead" or parts[4] != "eu":
        raise ValueError(f"Not an Arrowhead system common name: {common_name}")
    return parts[1], parts[2]


def cloud_identifier(common_name):
    """Arrowhead 5 cloud identifier '<Cloud>|<Organization>' of a system common name."""
    cloud, organization = cloud_of(common_name)
    return f"{cloud}|{organization}"


class RelayClient:
    def __init__(self, role, own_cn, host, port, ca_cert, chain_cert, key, handler, log=print):
        self.role = role
        self.own_cn = own_cn
        self.local_cloud, self.organization = cloud_of(own_cn)
        self.host, self.port = host, port
        self.ca_cert, self.chain_cert, self.key = ca_cert, chain_cert, key
        self.handler = handler          # handler(sender_cn, message) for messages that are not replies
        self.log = log
        self.pending = {}               # correlation id -> [threading.Event, reply]
        self.lock = threading.Lock()
        self.connected = threading.Event()
        self.client = None

    # --------------------------------------------------------------------------------------------- lifecycle
    def start(self):
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"{self.own_cn}-relay-{secrets.token_hex(3)}",
                             protocol=mqtt.MQTTv311)
        client.tls_set(ca_certs=self.ca_cert, certfile=self.chain_cert, keyfile=self.key,
                       cert_reqs=ssl.CERT_REQUIRED, tls_version=ssl.PROTOCOL_TLS_CLIENT)
        client.on_connect = self._on_connect
        client.on_disconnect = lambda *_args: self.connected.clear()
        client.on_message = self._on_message
        client.reconnect_delay_set(min_delay=1, max_delay=30)
        client.connect_async(self.host, self.port, keepalive=30)
        client.loop_start()
        self.client = client

    def status(self):
        return {"connected": self.connected.is_set(), "broker": f"{self.host}:{self.port}",
                "inbox": self.inbox_topic()}

    def inbox_topic(self):
        return f"arrowhead/relay/{self.local_cloud}/{self.role}/in/#"

    def _on_connect(self, client, _userdata, _flags, reason_code, _properties=None):
        if reason_code == 0:
            client.subscribe(self.inbox_topic(), qos=1)
            self.connected.set()
            self.log(f"Relay connected to {self.host}:{self.port}, inbox {self.inbox_topic()}")
        else:
            self.log(f"Relay connection refused: {reason_code}")

    # --------------------------------------------------------------------------------------------- messaging
    def send(self, target_cloud, message):
        """Publishes a message into target_cloud's inbox of this role, below the own certificate CN."""
        if not self.connected.wait(10):
            raise ConnectionError("Relay broker is not connected")
        message_id = message.setdefault("id", secrets.token_hex(12))
        topic = f"arrowhead/relay/{target_cloud}/{self.role}/in/{self.own_cn}/{message_id}"
        info = self.client.publish(topic, json.dumps(message, separators=(",", ":")), qos=1)
        info.wait_for_publish(10)
        return message_id

    def request(self, target_cloud, message, timeout=10):
        """Sends a request and waits for the reply that carries the same correlation id."""
        correlation = secrets.token_hex(12)
        message = {**message, "correlationId": correlation}
        waiter = [threading.Event(), None]
        with self.lock:
            self.pending[correlation] = waiter
        try:
            self.send(target_cloud, message)
            if not waiter[0].wait(timeout):
                raise TimeoutError(f"No relay reply from {target_cloud} within {timeout} s")
            return waiter[1]
        finally:
            with self.lock:
                self.pending.pop(correlation, None)

    def reply(self, sender_cn, request, payload):
        """Replies into the requesting cloud's inbox with the request's correlation id."""
        cloud, _organization = cloud_of(sender_cn)
        self.send(cloud, {**payload, "type": "reply", "correlationId": request.get("correlationId")})

    def _on_message(self, _client, _userdata, msg):
        parts = msg.topic.split("/")
        # arrowhead / relay / <cloud> / <role> / in / <senderCN> / <id>
        if len(parts) < 7 or parts[4] != "in":
            return
        sender_cn = parts[5]
        try:
            message = json.loads(msg.payload)
        except ValueError:
            self.log(f"Ignoring malformed relay message from {sender_cn}")
            return
        if message.get("type") == "reply":
            with self.lock:
                waiter = self.pending.get(message.get("correlationId"))
            if waiter:
                message["senderCN"] = sender_cn
                waiter[1] = message
                waiter[0].set()
            return
        threading.Thread(target=self._dispatch, args=(sender_cn, message), daemon=True).start()

    def _dispatch(self, sender_cn, message):
        started = time.time()
        try:
            self.handler(sender_cn, message)
        except Exception as error:  # the handler replies itself; this only keeps the loop alive
            self.log(f"Relay handler failed for {message.get('type')} from {sender_cn}: {error}")
        finally:
            if time.time() - started > 30:
                self.log(f"Slow relay handler for {message.get('type')} from {sender_cn}")
