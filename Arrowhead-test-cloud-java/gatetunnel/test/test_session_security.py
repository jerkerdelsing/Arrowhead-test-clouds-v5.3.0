"""Inter-cloud session protection (M2, M3): key exchange, sealing, replay window and operation scoping."""
import base64
import os
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

import session_security as ss


def name(*parts):
    oids = {"C": NameOID.COUNTRY_NAME, "O": NameOID.ORGANIZATION_NAME, "OU": NameOID.ORGANIZATIONAL_UNIT_NAME,
            "CN": NameOID.COMMON_NAME, "dnQualifier": NameOID.DN_QUALIFIER}
    return x509.Name([x509.NameAttribute(oids[k], v) for k, v in parts])


def certificate(subject, key, issuer, issuer_key, ca=False, constraint=None):
    now = datetime.now(timezone.utc)
    builder = (x509.CertificateBuilder().subject_name(subject).issuer_name(issuer).public_key(key.public_key())
               .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(days=1))
               .not_valid_after(now + timedelta(days=30))
               .add_extension(x509.BasicConstraints(ca=ca, path_length=0 if ca else None), critical=True))
    if constraint is not None:
        builder = builder.add_extension(x509.NameConstraints([x509.DirectoryName(constraint)], None), critical=True)
    return builder.sign(issuer_key, hashes.SHA256())


def pem(*certificates):
    return b"".join(c.public_bytes(serialization.Encoding.PEM) for c in certificates)


class Pki:
    """Organization CA cross-signing two cloud CAs, each name-constrained to its OU, and their GateTunnel relay keys."""

    def __init__(self, directory):
        key = lambda: rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.org_key = key()
        org = name(("C", "SE"), ("O", "Company"), ("CN", "Company.arrowhead.eu"))
        self.org = certificate(org, self.org_key, org, self.org_key, ca=True)
        self.dir = directory
        open(os.path.join(directory, "org-ca.crt"), "wb").write(pem(self.org))
        self.clouds = {}
        for cloud in ("TestCloud", "GoCloud"):
            ca_key = key()
            ca_name = name(("C", "SE"), ("O", "Company"), ("CN", f"{cloud}.Company.arrowhead.eu"))
            cross = certificate(ca_name, ca_key, org, self.org_key, ca=True,
                                constraint=name(("C", "SE"), ("O", "Company"), ("OU", cloud)))
            leaf_key = key()
            leaf = certificate(name(("C", "SE"), ("O", "Company"), ("OU", cloud),
                                    ("CN", f"GateTunnel.{cloud}.Company.arrowhead.eu"), ("dnQualifier", "sy")),
                               leaf_key, ca_name, ca_key)
            self.clouds[cloud] = {"ca_key": ca_key, "ca_name": ca_name, "cross": cross, "leaf": leaf}
            open(os.path.join(directory, f"{cloud}.key"), "wb").write(leaf_key.private_bytes(
                serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
            open(os.path.join(directory, f"{cloud}.chain"), "wb").write(pem(leaf, cross))

    def identity(self, cloud):
        return ss.RelayIdentity(os.path.join(self.dir, f"{cloud}.key"), os.path.join(self.dir, f"{cloud}.chain"),
                                os.path.join(self.dir, "org-ca.crt"))


class KeyExchangeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.pki = Pki(cls.temp.name)
        cls.provider_id, cls.consumer_id = cls.pki.identity("GoCloud"), cls.pki.identity("TestCloud")

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def session(self):
        return {"sessionId": "s-1", "consumer": "RandomDataProducer", "consumerCloud": "TestCloud|Company",
                "provider": "DataManager", "serviceDefinition": "dataHistorian",
                "consumerGateTunnel": "GateTunnel.TestCloud.Company.arrowhead.eu",
                "providerGateTunnel": "GateTunnel.GoCloud.Company.arrowhead.eu"}

    def exchange(self):
        provider = self.session()
        provider_private, provider["providerKey"] = ss.new_ephemeral()
        provider_signature = self.provider_id.sign(ss.transcript("provider", provider))
        consumer = {**self.session(), "providerKey": provider["providerKey"]}
        self.consumer_id.verify_peer(self.provider_id.chain_pem, consumer["providerGateTunnel"],
                                     base64.b64encode(provider_signature).decode(), ss.transcript("provider", consumer))
        consumer_private, consumer["consumerKey"] = ss.new_ephemeral()
        consumer_signature = self.consumer_id.sign(ss.transcript("consumer", consumer))
        provider["consumerKey"] = consumer["consumerKey"]
        self.provider_id.verify_peer(self.consumer_id.chain_pem, provider["consumerGateTunnel"],
                                     base64.b64encode(consumer_signature).decode(), ss.transcript("consumer", provider))
        return (ss.derive_keys(provider_private, consumer["consumerKey"], "s-1"),
                ss.derive_keys(consumer_private, provider["providerKey"], "s-1"), consumer, consumer_signature)

    def test_both_sides_derive_the_same_directional_keys(self):
        provider_keys, consumer_keys, _, _ = self.exchange()
        self.assertEqual(provider_keys, consumer_keys)
        self.assertNotEqual(provider_keys["c2p"], provider_keys["p2c"])

    def test_sealed_request_round_trip_and_tampering(self):
        keys, _, _, _ = self.exchange()
        envelope = ss.seal(keys["c2p"], "s-1", "c2p", 7, {"method": "POST", "path": "/datamanager/x"})
        self.assertNotIn("datamanager", str(envelope))
        sequence, content = ss.open_sealed(keys["c2p"], "s-1", "c2p", envelope)
        self.assertEqual((7, "/datamanager/x"), (sequence, content["path"]))
        with self.assertRaises(ss.SessionSecurityError):  # sequence number is authenticated
            ss.open_sealed(keys["c2p"], "s-1", "c2p", {**envelope, "seq": 8})
        with self.assertRaises(ss.SessionSecurityError):  # direction is authenticated (no reflection)
            ss.open_sealed(keys["c2p"], "s-1", "p2c", envelope)

    def test_other_cloud_cannot_pose_as_the_peer(self):
        _, _, consumer, signature = self.exchange()
        # the TestCloud GateTunnel's own valid chain is not the expected GoCloud peer
        with self.assertRaises(ss.SessionSecurityError):
            self.consumer_id.verify_peer(self.consumer_id.chain_pem, "GateTunnel.GoCloud.Company.arrowhead.eu",
                                         base64.b64encode(signature).decode(), ss.transcript("consumer", consumer))
        # a GoCloud-named leaf minted with the TestCloud CA key breaks the name constraint
        cloud = self.pki.clouds["TestCloud"]
        forged_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        forged = certificate(name(("C", "SE"), ("O", "Company"), ("OU", "GoCloud"),
                                  ("CN", "GateTunnel.GoCloud.Company.arrowhead.eu"), ("dnQualifier", "sy")),
                             forged_key, cloud["ca_name"], cloud["ca_key"])
        with self.assertRaises(ss.SessionSecurityError):
            self.consumer_id.verify_peer(pem(forged, cloud["cross"]).decode(), "GateTunnel.GoCloud.Company.arrowhead.eu",
                                         base64.b64encode(signature).decode(), ss.transcript("consumer", consumer))

    def test_modified_transcript_fails_the_signature(self):
        _, _, consumer, signature = self.exchange()
        changed = {**consumer, "provider": "TimeManager"}
        with self.assertRaises(ss.SessionSecurityError):
            self.provider_id.verify_peer(self.consumer_id.chain_pem, consumer["consumerGateTunnel"],
                                         base64.b64encode(signature).decode(), ss.transcript("consumer", changed))


class ReplayAndScopeTest(unittest.TestCase):
    def test_replay_window(self):
        window = ss.ReplayWindow(size=4)
        self.assertTrue(window.accept(1))
        self.assertFalse(window.accept(1))
        self.assertTrue(window.accept(3))
        self.assertTrue(window.accept(2))
        self.assertTrue(window.accept(10))
        self.assertFalse(window.accept(5))   # fell out of the window
        self.assertFalse(window.accept(0))

    def test_stale_timestamp_is_refused(self):
        key = os.urandom(32)
        envelope = ss.seal(key, "s", "c2p", 1, {"path": "/"})
        saved = ss.CLOCK_SKEW_SECONDS
        try:
            ss.CLOCK_SKEW_SECONDS = -1
            with self.assertRaises(ss.SessionSecurityError):
                ss.open_sealed(key, "s", "c2p", envelope)
        finally:
            ss.CLOCK_SKEW_SECONDS = saved

    def test_only_negotiated_operations(self):
        operations = {"put-data": {"method": "PUT", "path": "/data-historian/systems"}}
        base = "/datamanager"
        self.assertTrue(ss.operation_allowed("PUT", "/datamanager/data-historian/systems/RDP/services/x/data?a=1",
                                             base, operations))
        self.assertFalse(ss.operation_allowed("GET", "/datamanager/data-historian/systems", base, operations))
        self.assertFalse(ss.operation_allowed("PUT", "/datamanager/mgmt/data", base, operations))
        self.assertFalse(ss.operation_allowed("PUT", "/datamanager/data-historian/systemsX", base, operations))

    def test_path_normalization(self):
        operations = {"put-data": {"method": "PUT", "path": "/data-historian/systems"}}
        for path in ("/datamanager/data-historian/systems/../../mgmt", "/datamanager/data-historian/systems/%2e%2e/mgmt",
                     "/datamanager//data-historian/systems", "/datamanager/data-historian/systems/a%2fb",
                     "/datamanager/data-historian/systems/./x", "http://evil/datamanager/data-historian/systems",
                     "/datamanager/data-historian/systems\\..\\mgmt"):
            with self.assertRaises(ss.SessionSecurityError, msg=path):
                ss.operation_allowed("PUT", path, "/datamanager", operations)

    def test_expiry(self):
        now = time.time()
        self.assertFalse(ss.expired({"createdAt": now - 10, "lastUsedAt": now - 5}, now))
        self.assertTrue(ss.expired({"createdAt": now - ss.SESSION_MAX_AGE_SECONDS - 1, "lastUsedAt": now}, now))
        self.assertTrue(ss.expired({"createdAt": now - 10, "lastUsedAt": now - ss.SESSION_IDLE_SECONDS - 1}, now))


if __name__ == "__main__":
    unittest.main()
