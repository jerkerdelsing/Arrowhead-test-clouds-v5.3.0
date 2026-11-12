"""AMQP 0-9-1 client (pika) for the local-cloud broker of Arrowhead 5.2.2 Python microsystems.

The broker accepts only mutual TLS; it authenticates the client certificate with SASL EXTERNAL and uses its CN
as the user name. Routing keys and binding keys are checked per user against the broker access list (amqp/acl).
A connection is used by one thread only (pika is not thread-safe).
"""

import json
import time
import ssl

import pika

EXCHANGE = "arrowhead"


def connection_parameters(host, port, ca_cert, cert, key, name):
    context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=ca_cert)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    return pika.ConnectionParameters(
        host=host, port=port, credentials=pika.credentials.ExternalCredentials(),
        ssl_options=pika.SSLOptions(context, server_hostname=host), heartbeat=30, blocked_connection_timeout=30,
        connection_attempts=1, socket_timeout=10, client_properties={"connection_name": name})


class AmqpPublisher:
    """Publishes persistent JSON messages and waits for the broker's confirmation of each one."""

    def __init__(self, host, port, ca_cert, cert, key, name, exchange=EXCHANGE):
        self.parameters = connection_parameters(host, port, ca_cert, cert, key, name)
        self.exchange = exchange
        self.connection = None
        self.channel = None

    def connected(self):
        return bool(self.connection and self.connection.is_open and self.channel and self.channel.is_open)

    def publish(self, routing_key, message, message_id=None):
        if not self.connected():
            self.close()
            self.connection = pika.BlockingConnection(self.parameters)
            self.channel = self.connection.channel()
            self.channel.confirm_delivery()
        try:
            self.channel.basic_publish(self.exchange, routing_key, json.dumps(message, separators=(",", ":")),
                                       pika.BasicProperties(content_type="application/json", delivery_mode=2,
                                                            message_id=message_id))
        except Exception:
            self.close()  # e.g. ACCESS_REFUSED closes the channel; reconnect on the next publication
            raise

    def close(self):
        connection, self.connection, self.channel = self.connection, None, None
        if connection and connection.is_open:
            try:
                connection.close()
            except Exception:
                pass


class AmqpConsumer:
    """Consumes a durable queue of the own system and keeps its bindings equal to a desired set of binding keys.

    run() owns the connection (call it in its own thread); set_bindings() may be called from any thread.
    bindings_store(applied) persists the applied set, so bindings left by an earlier run can be removed after a restart.
    """

    def __init__(self, host, port, ca_cert, cert, key, name, queue, on_message, applied=(), bindings_store=None,
                 exchange=EXCHANGE, log=print):
        self.parameters = connection_parameters(host, port, ca_cert, cert, key, name)
        self.queue, self.exchange, self.on_message, self.log = queue, exchange, on_message, log
        self.bindings_store = bindings_store or (lambda _applied: None)
        self.applied = set(applied)     # bindings that may exist on the broker
        self.desired = set()
        self.connection = None
        self.channel = None
        self.connected = False
        self.last_error = None

    def set_bindings(self, keys):
        self.desired = set(keys)
        connection = self.connection
        if connection and connection.is_open:
            connection.add_callback_threadsafe(self._apply)

    def _apply(self):
        for key in sorted(self.applied - self.desired):
            self.channel.queue_unbind(self.queue, self.exchange, routing_key=key)
            self.applied.discard(key)
        for key in sorted(self.desired - self.applied):
            self.channel.queue_bind(self.queue, self.exchange, routing_key=key)
            self.applied.add(key)
        self.bindings_store(sorted(self.applied))

    def _deliver(self, channel, method, _properties, body):
        try:
            self.on_message(method.routing_key, body)
        finally:
            channel.basic_ack(method.delivery_tag)

    def run(self):
        while True:
            try:
                self.connection = pika.BlockingConnection(self.parameters)
                self.channel = self.connection.channel()
                self.channel.queue_declare(self.queue, durable=True)
                self.channel.basic_qos(prefetch_count=100)
                self._apply()
                self.channel.basic_consume(self.queue, self._deliver)
                self.connected, self.last_error = True, None
                self.channel.start_consuming()
            except Exception as error:  # broker restart, refused binding, ...
                self.last_error = f"AMQP consumer: {error}"
                self.log(self.last_error)
            finally:
                self.connected = False
                try:
                    if self.connection and self.connection.is_open:
                        self.connection.close()
                except Exception:
                    pass
                self.connection = self.channel = None
            time.sleep(5)
