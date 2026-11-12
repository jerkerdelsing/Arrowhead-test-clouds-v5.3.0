import importlib.util
import os
import tempfile
import unittest


class SessionStoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bootstrap = tempfile.TemporaryDirectory()
        os.environ["DB_PATH"] = os.path.join(cls.bootstrap.name, "bootstrap.db")
        source = os.path.join(os.path.dirname(__file__), "..", "src", "server.py")
        spec = importlib.util.spec_from_file_location("gatetunnel_server", source)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    @classmethod
    def tearDownClass(cls):
        cls.bootstrap.cleanup()

    def setUp(self):
        self.case = tempfile.TemporaryDirectory()
        self.store = self.module.SessionStore(os.path.join(self.case.name, "sessions.db"))
        self.request = {
            "consumer": {"name": "Consumer", "address": "consumer", "port": 9000},
            "provider": {"name": "Provider", "address": "provider", "port": 9001},
            "consumerCloud": {"name": "CloudA", "operator": "Example"},
            "providerCloud": {"name": "CloudB", "operator": "Example"},
            "relay": {"name": "relay", "address": "relay", "port": 61617},
            "serviceDefinition": "temperature"
        }

    def tearDown(self):
        self.case.cleanup()

    def test_provider_consumer_and_close_lifecycle(self):
        created = self.store.create(self.request)
        self.assertEqual(created["state"], "PROVIDER_READY")
        active = self.store.connect_consumer({"queueId": created["queueId"]})
        self.assertEqual(active["state"], "ACTIVE")
        self.assertEqual(active["tunnelPort"], created["tunnelPort"])
        self.assertEqual(self.store.close(session_id=created["sessionId"]), 1)
        self.assertEqual(self.store.all()[0]["state"], "CLOSED")

    def test_required_connection_fields(self):
        with self.assertRaises(ValueError):
            self.store.create({"serviceDefinition": "temperature"})


if __name__ == "__main__":
    unittest.main()
