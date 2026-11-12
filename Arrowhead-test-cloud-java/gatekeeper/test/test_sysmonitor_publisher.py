import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
from sysmonitor_publisher import SysMonitorPublisher


class SysMonitorPublisherTests(unittest.TestCase):
    def publisher(self, healthy=True):
        return SysMonitorPublisher("Gatekeeper", "TestCloud", "amqp-broker", 5671, "ca", "cert", "key",
                                   health=lambda: (healthy, "detail"), service_count=lambda: 4)

    def test_registration_is_native_and_cert_auth(self):
        registration = self.publisher().service_registration()
        self.assertEqual(registration["metadata"]["publisherMode"], "native")
        interface = registration["interfaces"][0]
        self.assertEqual((interface["templateName"], interface["policy"]), ("generic_amqps", "CERT_AUTH"))
        self.assertEqual(interface["properties"]["exchange"], "arrowhead")
        self.assertEqual(interface["properties"]["baseRoutingKey"], "TestCloud.sysmonitor.Gatekeeper.Gatekeeper")
        self.assertEqual(interface["properties"]["operations"], ["echo", "power", "status"])

    def test_observations_follow_the_envelope(self):
        echo, power, status = self.publisher().observations(now=1791700000.5)
        self.assertEqual(echo["providerSystem"], "Gatekeeper")
        self.assertEqual(echo["value"]["status"], "alive")
        self.assertEqual(echo["sourceTime"], "2026-10-11T06:26:40.500Z")
        self.assertEqual(power["value"]["supplyType"], "line")
        self.assertEqual(status["value"]["serviceCount"], 4)
        self.assertEqual([o["sequence"] for o in (echo, power, status)], [1, 2, 3])
        self.assertEqual(len({o["observationId"] for o in (echo, power, status)}), 3)

    def test_unhealthy_store_degrades_echo(self):
        echo = self.publisher(healthy=False).observations()[0]
        self.assertEqual(echo["value"]["status"], "degraded")
        self.assertEqual(echo["quality"], "uncertain")


if __name__ == "__main__":
    unittest.main()
