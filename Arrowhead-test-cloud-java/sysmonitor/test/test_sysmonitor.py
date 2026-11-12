import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
import server
from server import Store, SysMonitor, epoch, normalize_observation


class SysMonitorTests(unittest.TestCase):
    def test_normalizes_monitoring_envelope(self):
        result = normalize_observation({
            "observationId": "obs-1", "observationType": "power",
            "sourceTime": "2026-09-30T12:00:00Z", "value": {"supplyType": "battery", "levelPercent": 42}
        }, "TestCloud.sysmonitor.Battery.monitoring-01.power", "2026-09-30T12:00:01Z")
        self.assertEqual(result["providerSystem"], "Battery")
        self.assertEqual(result["observationId"], "obs-1")
        self.assertEqual(result["pipeline"]["sysMonitor"], "SysMonitor")

    def test_rejects_topic_payload_type_mismatch(self):
        with self.assertRaises(ValueError):
            normalize_observation({"observationType": "echo", "sourceTime": "2026-09-30T12:00:00Z",
                                   "value": {"status": "alive"}},
                                  "TestCloud.sysmonitor.A.B.power")

    def test_rejects_payload_identity_that_does_not_match_topic(self):
        with self.assertRaises(ValueError):
            normalize_observation({"providerSystem": "Other", "observationType": "echo",
                                   "sourceTime": "2026-09-30T12:00:00Z",
                                   "value": {"status": "alive"}},
                                  "TestCloud.sysmonitor.A.B.echo")

    def test_validates_baseline_echo_and_power_models(self):
        echo = normalize_observation({"observationType": "echo", "sourceTime": "2026-09-30T12:00:00Z",
                                      "value": {"status": "alive", "uptimeSeconds": 10}},
                                     "TestCloud.sysmonitor.A.B.echo")
        power = normalize_observation({"observationType": "power", "sourceTime": "2026-09-30T12:00:00Z",
                                       "value": {"supplyType": "line", "voltage": 230}},
                                      "TestCloud.sysmonitor.A.B.power")
        self.assertEqual(echo["value"]["status"], "alive")
        self.assertEqual(power["value"]["supplyType"], "line")

    def test_store_deduplicates_and_versions_policies(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(os.path.join(directory, "monitor.db"))
            observation = normalize_observation({"observationId": "same", "sourceTime": "2026-09-30T12:00:00Z",
                                                 "value": {"status": "alive"}},
                                                "TestCloud.sysmonitor.A.B.echo")
            self.assertTrue(store.enqueue(observation))
            self.assertFalse(store.enqueue(observation))
            subscription = store.put_subscription("A", ["echo"], True, "LocalCloudManager")
            self.assertEqual(subscription["revision"], 1)
            subscription = store.put_subscription("A", ["echo", "status"], False, "LocalCloudManager", 1)
            self.assertEqual((subscription["revision"], subscription["enabled"]), (2, False))
            with self.assertRaises(RuntimeError):
                store.put_subscription("A", ["echo"], True, "LocalCloudManager", 1)

    def observe(self, provider, kind, source_time, received_time, value=None):
        return normalize_observation({"observationType": kind, "sourceTime": source_time,
                                      "value": value or ({"status": "alive"} if kind == "echo" else
                                                         {"supplyType": "line"} if kind == "power" else {"state": "running"})},
                                     f"TestCloud.sysmonitor.{provider}.{provider}.{kind}", received_time)

    def test_stores_observations_from_many_systems_in_own_history(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(os.path.join(directory, "monitor.db"))
            for provider in ("A", "B", "C"):
                for minute, kind in enumerate(("echo", "power", "status")):
                    store.enqueue(self.observe(provider, kind, f"2026-10-12T10:0{minute}:00Z", f"2026-10-12T10:0{minute}:01Z"))
            systems = {item["systemName"]: item for item in store.history_systems()}
            self.assertEqual(sorted(systems), ["A", "B", "C"])
            self.assertEqual(systems["B"]["observationCount"], 3)
            self.assertEqual(systems["B"]["lastObservationTime"], "2026-10-12T10:02:00Z")
            self.assertEqual(store.counts(), {"pending": 9, "stored": 9})

    def test_queries_history_by_type_time_and_count(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(os.path.join(directory, "monitor.db"))
            for minute in range(5):
                store.enqueue(self.observe("A", "echo", f"2026-10-12T10:0{minute}:00Z", f"2026-10-12T10:0{minute}:01Z"))
                store.enqueue(self.observe("A", "power", f"2026-10-12T10:0{minute}:30Z", f"2026-10-12T10:0{minute}:31Z"))
            echoes = store.history_query("A", ["echo"])
            self.assertEqual(len(echoes), 5)
            self.assertEqual(echoes[0]["sourceTime"], "2026-10-12T10:04:00Z")
            window = store.history_query("A", None, epoch("2026-10-12T10:01:00Z"), epoch("2026-10-12T10:02:00Z"))
            self.assertEqual([item["sourceTime"] for item in window],
                             ["2026-10-12T10:02:00Z", "2026-10-12T10:01:30Z", "2026-10-12T10:01:00Z"])
            self.assertEqual(len(store.history_query("A", None, count=2)), 2)
            self.assertEqual(store.history_query("Unknown"), [])

    def test_latest_returns_newest_observation_per_type(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(os.path.join(directory, "monitor.db"))
            store.enqueue(self.observe("A", "echo", "2026-10-12T10:00:00Z", "2026-10-12T10:00:01Z"))
            store.enqueue(self.observe("A", "echo", "2026-10-12T10:01:00Z", "2026-10-12T10:01:01Z", {"status": "degraded"}))
            store.enqueue(self.observe("A", "power", "2026-10-12T10:00:30Z", "2026-10-12T10:00:31Z"))
            latest = store.history_latest("A")
            self.assertEqual(sorted(latest), ["echo", "power"])
            self.assertEqual(latest["echo"]["value"]["status"], "degraded")
            self.assertEqual(store.history_latest("Unknown"), {})

    def test_published_observations_leave_outbox_but_stay_in_history(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(os.path.join(directory, "monitor.db"))
            observation = self.observe("A", "echo", "2026-10-12T10:00:00Z", "2026-10-12T10:00:01Z")
            store.enqueue(observation)
            store.published(observation["observationId"])
            self.assertEqual(store.pending(), [])
            self.assertEqual(store.counts(), {"pending": 0, "stored": 1})

    def test_retention_prunes_only_expired_observations(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(os.path.join(directory, "monitor.db"))
            store.enqueue(self.observe("A", "echo", "2026-09-01T10:00:00Z", "2026-09-01T10:00:01Z"))
            store.enqueue(self.observe("A", "echo", "2026-10-12T10:00:00Z", "2026-10-12T10:00:01Z"))
            removed = store.prune(30, now=epoch("2026-10-12T12:00:00Z"))
            self.assertEqual(removed, 1)
            self.assertEqual([item["sourceTime"] for item in store.history_query("A")], ["2026-10-12T10:00:00Z"])

    def test_rejects_invalid_subscriptions(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(os.path.join(directory, "monitor.db"))
            for provider, types in (("A", []), ("A", ["#"]), ("A", ["echo", "*"]), ("A.B", ["echo"]), ("*", ["echo"])):
                with self.assertRaises(ValueError):
                    store.put_subscription(provider, types)

    def monitor(self, directory):
        runtime = SysMonitor(Store(os.path.join(directory, "monitor.db")))
        runtime.orchestrated_providers = {
            name: {"providerSystem": name, "baseRoutingKey": f"TestCloud.sysmonitor.{name}.{name}",
                   "observationTypes": ["echo", "power", "status"]} for name in ("A", "B", "C")}
        return runtime

    def test_subscriptions_select_providers_and_observation_types(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = self.monitor(directory)
            runtime.store.put_subscription("A", ["status", "unknownType"])
            runtime.store.put_subscription("B", ["*"], enabled=False)
            self.assertEqual(runtime.binding_keys(), {"TestCloud.sysmonitor.A.A.status", "TestCloud.sysmonitor.C.C.*"})
            view = {item["providerSystem"]: item for item in runtime.providers_view()}
            self.assertEqual((view["A"]["subscribedTypes"], view["A"]["selection"]), (["status"], "subscription"))
            self.assertEqual(view["B"]["subscribedTypes"], [])
            self.assertEqual((view["C"]["subscribedTypes"], view["C"]["selection"]), (["echo", "power", "status"], "default"))
            self.assertEqual(runtime.subscriptions_view()[0]["unknownTypes"], ["unknownType"])

    def test_default_none_subscribes_only_selected_providers(self):
        with tempfile.TemporaryDirectory() as directory:
            runtime = self.monitor(directory)
            runtime.store.put_subscription("B", ["echo"])
            default, server.DEFAULT_SUBSCRIPTION = server.DEFAULT_SUBSCRIPTION, "none"
            try:
                self.assertEqual(runtime.binding_keys(), {"TestCloud.sysmonitor.B.B.echo"})
            finally:
                server.DEFAULT_SUBSCRIPTION = default

    def test_amqp_bindings_survive_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            store = Store(os.path.join(directory, "monitor.db"))
            store.store_amqp_bindings(["TestCloud.sysmonitor.A.A.echo"])
            self.assertEqual(Store(os.path.join(directory, "monitor.db")).amqp_bindings(), ["TestCloud.sysmonitor.A.A.echo"])


if __name__ == "__main__":
    unittest.main()
