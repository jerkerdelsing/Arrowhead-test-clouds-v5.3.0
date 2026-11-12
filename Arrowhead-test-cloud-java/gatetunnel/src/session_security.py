"""End-to-end protection and scoping of inter-cloud GateTunnel sessions (security findings M2 and M3).

Key exchange (once per session, carried by the Gatekeepers' ICN messages and the first tunnel request):
  - each GateTunnel creates an ephemeral X25519 key for the session and signs a transcript of the session parameters and
    the ephemeral key(s) with its relay key (RSA-PSS, SHA-256);
  - the signature comes with the GateTunnel's relay chain (relay certificate + cross-certificate of its cloud CA), which
    the peer verifies against the organization CA, the cross-certificate's name constraint and the expected peer name;
  - both sides derive one AES-256-GCM key per direction from the X25519 secret (HKDF-SHA256, salt = session id).
Every relayed request and reply is then encrypted and authenticated (AES-GCM, AAD = session, direction, sequence).
Requests carry a sequence number and a timestamp: duplicates and messages outside the time window are refused, and
a reply must carry the sequence number of its request. The relay and holders of other GateTunnel keys see only
ciphertext; the ephemeral keys give forward secrecy.

Scoping: a session admits only the negotiated operations (HTTP method and operation path below the provider's base
path), on a normalized path, and expires after SESSION_MAX_AGE_SECONDS or SESSION_IDLE_SECONDS without use.
"""
import base64
import json
import os
import re
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote, urlsplit

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, x25519
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.x509.oid import ExtensionOID, NameOID

PROTOCOL = "AH-GT-1"
CLOCK_SKEW_SECONDS = int(os.getenv("SESSION_CLOCK_SKEW_SECONDS", "120"))
REPLAY_WINDOW = 4096
SESSION_MAX_AGE_SECONDS = int(os.getenv("SESSION_MAX_AGE_SECONDS", str(12 * 3600)))
SESSION_IDLE_SECONDS = int(os.getenv("SESSION_IDLE_SECONDS", "3600"))


def b64(data):
    return base64.b64encode(data).decode()


def unb64(text):
    return base64.b64decode(str(text or ""), validate=True)


class SessionSecurityError(Exception):
    pass


# ---- relay identity: own key and chain, verification of the peer's chain ----

class RelayIdentity:
    def __init__(self, key_path, chain_path, org_ca_path):
        self.key = serialization.load_pem_private_key(Path(key_path).read_bytes(), password=None)
        self.chain_pem = Path(chain_path).read_text()
        self.org_ca = x509.load_pem_x509_certificate(Path(org_ca_path).read_bytes())

    def sign(self, transcript):
        return self.key.sign(transcript, padding.PSS(mgf=padding.MGF1(hashes.SHA256()),
                                                     salt_length=padding.PSS.DIGEST_LENGTH), hashes.SHA256())

    def verify_peer(self, chain_pem, expected_cn, signature, transcript, now=None):
        """Verifies leaf -> cross-certificate -> organization CA, the name constraint, the expected peer name and
        profile, and the signature over the transcript. Raises SessionSecurityError."""
        certificates = x509.load_pem_x509_certificates(str(chain_pem or "").encode())
        if len(certificates) != 2:
            raise SessionSecurityError("peer chain must be relay certificate + cross-certificate")
        leaf, cross = certificates
        moment = now or datetime.now(timezone.utc)
        try:
            leaf.verify_directly_issued_by(cross)
            cross.verify_directly_issued_by(self.org_ca)
        except (ValueError, TypeError, InvalidSignature) as error:
            raise SessionSecurityError(f"peer chain does not verify: {error}") from error
        for certificate in (leaf, cross):
            if not certificate.not_valid_before_utc <= moment <= certificate.not_valid_after_utc:
                raise SessionSecurityError("peer chain is outside its validity period")
        if not cross.extensions.get_extension_for_oid(ExtensionOID.BASIC_CONSTRAINTS).value.ca:
            raise SessionSecurityError("peer cross-certificate is not a CA")
        if leaf.extensions.get_extension_for_oid(ExtensionOID.BASIC_CONSTRAINTS).value.ca:
            raise SessionSecurityError("peer relay certificate must not be a CA")
        permitted = cross.extensions.get_extension_for_oid(ExtensionOID.NAME_CONSTRAINTS).value.permitted_subtrees or []
        subtree = [name.value for name in permitted if isinstance(name, x509.DirectoryName)]
        if not any(list(leaf.subject.rdns)[:len(list(tree.rdns))] == list(tree.rdns) for tree in subtree):
            raise SessionSecurityError("peer relay certificate is outside its cloud's name constraint")
        names = leaf.subject.get_attributes_for_oid(NameOID.COMMON_NAME)
        profiles = leaf.subject.get_attributes_for_oid(NameOID.DN_QUALIFIER)
        if not names or names[0].value != expected_cn:
            raise SessionSecurityError(f"peer relay certificate is not {expected_cn}")
        if not profiles or profiles[0].value != "sy":
            raise SessionSecurityError("peer relay certificate is not a system (sy) certificate")
        try:
            leaf.public_key().verify(unb64(signature), transcript,
                                     padding.PSS(mgf=padding.MGF1(hashes.SHA256()),
                                                 salt_length=padding.PSS.DIGEST_LENGTH), hashes.SHA256())
        except (InvalidSignature, ValueError) as error:
            raise SessionSecurityError("peer key-exchange signature is invalid") from error


def transcript(role, session):
    """Canonical bytes both sides sign: protocol, role, session parameters and the ephemeral key(s) so far."""
    fields = [PROTOCOL, role, session["sessionId"], session["consumer"], session["consumerCloud"], session["provider"],
              session["serviceDefinition"], session["consumerGateTunnel"], session["providerGateTunnel"],
              session.get("providerKey", "")]
    if role == "consumer":
        fields.append(session.get("consumerKey", ""))
    return "\n".join(str(field) for field in fields).encode()


def new_ephemeral():
    private = x25519.X25519PrivateKey.generate()
    public = private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return private, b64(public)


def derive_keys(private, peer_public_b64, session_id):
    shared = private.exchange(x25519.X25519PublicKey.from_public_bytes(unb64(peer_public_b64)))
    keys = {}
    for direction in ("c2p", "p2c"):
        keys[direction] = HKDF(algorithm=hashes.SHA256(), length=32, salt=session_id.encode(),
                               info=f"{PROTOCOL} {direction}".encode()).derive(shared)
    return keys


# ---- message protection ----

def seal(key, session_id, direction, sequence, content):
    nonce = os.urandom(12)
    aad = f"{PROTOCOL}|{session_id}|{direction}|{sequence}".encode()
    plaintext = json.dumps({**content, "timestamp": time.time()}, separators=(",", ":")).encode()
    return {"seq": sequence, "nonce": b64(nonce), "ciphertext": b64(AESGCM(key).encrypt(nonce, plaintext, aad))}


def open_sealed(key, session_id, direction, envelope):
    try:
        sequence = int(envelope["seq"])
        aad = f"{PROTOCOL}|{session_id}|{direction}|{sequence}".encode()
        content = json.loads(AESGCM(key).decrypt(unb64(envelope["nonce"]), unb64(envelope["ciphertext"]), aad))
    except Exception as error:
        raise SessionSecurityError("message does not decrypt or authenticate") from error
    if abs(time.time() - float(content.get("timestamp", 0))) > CLOCK_SKEW_SECONDS:
        raise SessionSecurityError("message is outside the accepted time window")
    return sequence, content


class ReplayWindow:
    """Accepts each sequence number once, within a sliding window above the highest seen."""

    def __init__(self, size=REPLAY_WINDOW):
        self.size, self.highest, self.seen, self.lock = size, 0, set(), threading.Lock()

    def accept(self, sequence):
        with self.lock:
            if sequence <= 0 or sequence in self.seen or sequence <= self.highest - self.size:
                return False
            self.seen.add(sequence)
            self.highest = max(self.highest, sequence)
            self.seen = {s for s in self.seen if s > self.highest - self.size}
            return True


# ---- session scoping (M2) ----

_UNSAFE = re.compile(r"(^|/)\.{1,2}(/|$)|//|\\")


def normalized_path(raw):
    """The request path without query, refused when it is not in normal form (dot segments, empty segments,
    backslashes, encoded slashes or dots) - so a prefix check cannot be escaped."""
    parts = urlsplit(str(raw or ""))
    path = parts.path
    if not path.startswith("/") or parts.scheme or parts.netloc:
        raise SessionSecurityError("path must be absolute")
    lowered = path.lower()
    if "%2f" in lowered or "%5c" in lowered or "%2e" in lowered or "%00" in lowered:
        raise SessionSecurityError("encoded separators or dots are not allowed in the path")
    if _UNSAFE.search(unquote(path)):
        raise SessionSecurityError("path is not normalized")
    return path


def operation_allowed(method, raw_path, base_path, operations):
    """True when method and path match one negotiated operation: <basePath><operation path>[/<path parameters>]."""
    path = normalized_path(raw_path)
    base = (base_path or "").rstrip("/")
    for operation in (operations or {}).values():
        if str(operation.get("method", "")).upper() != str(method).upper():
            continue
        prefix = base + "/" + str(operation.get("path", "")).strip("/")
        prefix = prefix.rstrip("/") or "/"
        if path == prefix or path.startswith(prefix + "/"):
            return True
    return False


def expired(session, now=None):
    moment = now or time.time()
    return (moment - session["createdAt"] > SESSION_MAX_AGE_SECONDS
            or moment - session.get("lastUsedAt", session["createdAt"]) > SESSION_IDLE_SECONDS)
