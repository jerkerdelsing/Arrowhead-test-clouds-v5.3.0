"""Native sysMonitor publisher (SysMonitor-AMQP-IDD-5.2.2) for Arrowhead 5.2.2 Python microsystems.

Publishes echo, power and status observations about the hosting system to the local-cloud AMQP broker
(topic exchange "arrowhead", routing key <Cloud>.sysmonitor.<System>.<serviceInstance>.<observationType>).
"""

import threading
import time
from datetime import datetime, timezone

from amqp_client import EXCHANGE, AmqpPublisher

OBSERVATION_TYPES = ["echo", "power", "status"]


class SysMonitorPublisher:
    def __init__(self, system_name, local_cloud, host, port, ca_cert, cert, key,
                 health=None, service_count=None, interval=30, service_instance=None):
        self.system_name = system_name
        self.service_instance = service_instance or system_name
        self.base_routing_key = f"{local_cloud}.sysmonitor.{system_name}.{self.service_instance}"
        self.host, self.port = host, port
        self.ca_cert, self.cert, self.key = ca_cert, cert, key
        self.health = health or (lambda: (True, f"{system_name} is running"))
        self.service_count = service_count or (lambda: 0)
        self.interval = interval
        self.sequence = 0
        self.started = time.time()
        self.publisher = None
        self.last_error = None

    def service_registration(self):
        """ServiceRegistry service-discovery register payload of the native sysMonitor offer."""
        return {
            "serviceDefinitionName": "sysMonitor", "version": "1.0.0", "expiresAt": None,
            "metadata": {"contract": "SysMonitor-AMQP-IDD-5.2.2", "schemaVersion": "1.0",
                         "publisherMode": "native", "observationTypes": OBSERVATION_TYPES,
                         "delivery": "persistent, publisher-confirmed"},
            "interfaces": [{"templateName": "generic_amqps", "protocol": "amqps", "policy": "CERT_AUTH",
                            "properties": {"accessAddresses": [self.host], "accessPort": self.port,
                                           "exchange": EXCHANGE, "baseRoutingKey": self.base_routing_key,
                                           "operations": OBSERVATION_TYPES}}]}

    def observation(self, observation_type, value, unit, quality, now=None):
        now = now or time.time()
        self.sequence += 1
        observation = {
            "schemaVersion": "1.0",
            "observationId": f"{self.system_name}-{observation_type}-{int(now * 1000)}-{self.sequence}",
            "providerSystem": self.system_name,
            "serviceInstance": self.service_instance,
            "observationType": observation_type,
            "sourceTime": datetime.fromtimestamp(now, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "sequence": self.sequence,
            "value": value,
            "quality": quality,
            "metadata": {"publisherMode": "native"},
        }
        if unit is not None:
            observation["unit"] = unit
        return observation

    def observations(self, now=None):
        now = now or time.time()
        healthy, detail = self.health()
        quality = "good" if healthy else "uncertain"
        return [
            self.observation("echo", {"status": "alive" if healthy else "degraded",
                                      "uptimeSeconds": int(now - self.started), "detail": detail}, None, quality, now),
            self.observation("power", {"supplyType": "line", "state": "available"}, "1", "good", now),
            self.observation("status", {"state": "running", "health": "healthy" if healthy else "degraded",
                                        "serviceCount": self.service_count()}, "1", quality, now),
        ]

    def publish_once(self):
        if self.publisher is None:
            self.publisher = AmqpPublisher(self.host, self.port, self.ca_cert, self.cert, self.key,
                                           f"{self.system_name}-sysMonitor")
        for observation in self.observations():
            self.publisher.publish(f"{self.base_routing_key}.{observation['observationType']}", observation,
                                   observation["observationId"])

    def loop(self):
        while True:
            started = time.monotonic()
            try:
                self.publish_once()
                self.last_error = None
            except Exception as error:
                self.last_error = str(error)
                print(f"sysMonitor publication failed: {error}", flush=True)
            time.sleep(max(1, self.interval - (time.monotonic() - started)))

    def start(self):
        threading.Thread(target=self.loop, daemon=True, name="sysMonitor-publisher").start()
