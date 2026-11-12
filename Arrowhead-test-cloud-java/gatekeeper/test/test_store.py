import importlib.util
import os
import tempfile
import unittest


class StoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tempdir = tempfile.TemporaryDirectory()
        os.environ["DB_PATH"] = os.path.join(cls.tempdir.name, "bootstrap.db")
        source = os.path.join(os.path.dirname(__file__), "..", "src", "server.py")
        spec = importlib.util.spec_from_file_location("gatekeeper_server", source)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    @classmethod
    def tearDownClass(cls):
        cls.tempdir.cleanup()

    def setUp(self):
        self.case = tempfile.TemporaryDirectory()
        self.store = self.module.Store(os.path.join(self.case.name, "gatekeeper.db"))

    def tearDown(self):
        self.case.cleanup()

    def test_cloud_upsert_and_delete(self):
        result = self.store.put_clouds([{
            "name": "RemoteCloud", "operator": "Example", "gatekeeperAddress": "remote.example", "gatekeeperPort": 8449
        }])
        self.assertEqual(result[0]["name"], "RemoteCloud")
        self.assertTrue(result[0]["secure"])
        self.assertEqual(self.store.delete_cloud("Example", "RemoteCloud"), 1)
        self.assertEqual(self.store.clouds(), [])

    def test_relay_validation_and_persistence(self):
        result = self.store.put_relays([{"name": "relay-a", "address": "relay", "port": 61617}])
        self.assertEqual(result[0]["port"], 61617)
        with self.assertRaises(ValueError):
            self.store.put_relays([{"name": "bad", "address": "relay", "port": 70000}])


if __name__ == "__main__":
    unittest.main()
