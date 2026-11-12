#!/usr/bin/env python3
"""Demo device for the Arrowhead 5.2.2 onboarding procedure.

The device starts with nothing but its manufacturer-issued bootstrap certificate and the local-cloud CA certificate
(to verify the servers). It walks the procedure end to end:

  1. bootstrap certificate          -> Onboarding onboard-with-csr  -> onboarding (on) certificate
  2. onboarding certificate         -> Onboarding onboard-device    -> device (de) certificate, DeviceRegistry entry
  3. device certificate             -> Onboarding onboard-system    -> system (sy) certificate and identity, per system
  4. system certificate + password  -> Authentication identity-login -> identity token
  5. ServiceRegistry systemDiscovery register (deviceName) and serviceDiscovery register
  6. DynamicServiceOrchestration pull dataHistorian, then DataManager put-data
  7. optionally: Onboarding offboard-device, after which the identity can no longer log in

Every private key is generated on the device and never leaves it: each step sends a CSR.
"""

import base64
import json
import os
import socket
import ssl
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

CLOUD = os.getenv("CLOUD_COMMON_NAME", "TestCloud.Company.arrowhead.eu")
DEVICE = os.getenv("DEVICE_NAME", "Device1")
SYSTEM = os.getenv("SYSTEM_NAME", "DemoSensor")
HOST = os.getenv("DEVICE_HOST", "device-demo")
PORT = int(os.getenv("SERVICE_PORT", "8600"))
ONBOARDING = os.getenv("ONBOARDING_URL", "https://onboarding:8435")
AUTHENTICATION = os.getenv("AUTHENTICATION_URL", "https://authentication:8444")
REGISTRY = os.getenv("SERVICE_REGISTRY_URL", "https://serviceregistry:8443")
ORCHESTRATOR = os.getenv("ORCHESTRATOR_URL", "https://serviceorchestration-dynamic:8441")
CA_CERT = os.getenv("CA_CERT", "/certs/ca.crt")
BOOTSTRAP_CERT = os.getenv("BOOTSTRAP_CERT", "/bootstrap/device1-bootstrap.crt")
BOOTSTRAP_KEY = os.getenv("BOOTSTRAP_KEY", "/bootstrap/device1-bootstrap.key")
OFFBOARD = os.getenv("OFFBOARD", "0") == "1"
WORK = tempfile.mkdtemp(prefix="device-")
summary = {"device": DEVICE, "system": SYSTEM, "steps": []}


def step(name, **details):
    summary["steps"].append({"step": name, **details})
    print(f"[{DEVICE}] {name}: {json.dumps(details)}", flush=True)


class Credential:
    """A private key generated on the device and the certificate chain issued for it."""

    def __init__(self, label):
        self.label = label
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
        self.cert_file = self.key_file = None

    def csr(self, common_name, dns_names=()):
        builder = x509.CertificateSigningRequestBuilder().subject_name(
            x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)]))
        if dns_names:
            builder = builder.add_extension(x509.SubjectAlternativeName([x509.DNSName(n) for n in dns_names]), critical=False)
        return base64.b64encode(builder.sign(self.key, hashes.SHA256()).public_bytes(serialization.Encoding.DER)).decode()

    def store(self, chain):
        pem = b"".join(x509.load_der_x509_certificate(base64.b64decode(c)).public_bytes(serialization.Encoding.PEM) for c in chain)
        self.cert_file, self.key_file = os.path.join(WORK, self.label + ".crt"), os.path.join(WORK, self.label + ".key")
        open(self.cert_file, "wb").write(pem)
        open(self.key_file, "wb").write(self.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                               serialization.NoEncryption()))
        os.chmod(self.key_file, 0o600)
        leaf = x509.load_der_x509_certificate(base64.b64decode(chain[0]))
        return {"subject": leaf.subject.rfc4514_string(), "notAfter": leaf.not_valid_after_utc.isoformat()}


def context(cert_file, key_file):
    ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=CA_CERT)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(cert_file, key_file)
    return ctx


def call(url, cert_file, key_file, payload=None, method="POST", token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer IDENTITY-TOKEN//{token}"
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, context=context(cert_file, key_file), timeout=20) as response:
            body = response.read()
            return response.status, (json.loads(body) if body else None)
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        raise RuntimeError(f"{method} {url} -> {error.code}: {body[:400]}") from None


class Service(BaseHTTPRequestHandler):
    """The demoMeasurement service the onboarded system offers (served with its system certificate)."""
    latest = {"n": "demo", "v": None}

    def do_GET(self):
        body = json.dumps(Service.latest).encode() if self.path == "/demo/latest" else b'{"error":"not found"}'
        self.send_response(200 if self.path == "/demo/latest" else 404)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)

    def log_message(self, *_args):
        pass


def main():
    address = socket.gethostbyname(socket.gethostname())

    # 1. bootstrap certificate -> onboarding certificate
    onboarding = Credential("onboarding")
    _, response = call(f"{ONBOARDING}/onboarding/certificate/csr", BOOTSTRAP_CERT, BOOTSTRAP_KEY,
                       {"certificateSigningRequest": onboarding.csr(f"{DEVICE}.{CLOUD}")})
    step("1 onboard-with-csr (bootstrap certificate)", **onboarding.store(response["certificateChain"]),
         registryServices=sorted({s["serviceDefinition"]["name"] for s in response["services"]}))

    # 2. onboarding certificate -> device certificate and DeviceRegistry entry
    device = Credential("device")
    _, response = call(f"{ONBOARDING}/onboarding/device", onboarding.cert_file, onboarding.key_file,
                       {"certificateSigningRequest": device.csr(f"{DEVICE}.{CLOUD}"), "addresses": [address],
                        "metadata": {"vendor": "Test Manufacturer", "model": "demo-device"}})
    step("2 onboard-device (onboarding certificate)", **device.store(response["certificateChain"]),
         approvedSystems=response["approvedSystems"])

    # 3. device certificate -> system certificate and identity
    system = Credential("system")
    _, response = call(f"{ONBOARDING}/onboarding/system", device.cert_file, device.key_file,
                       {"systemName": SYSTEM, "certificateSigningRequest": system.csr(f"{SYSTEM}.{CLOUD}", [HOST])})
    password = response["credentials"]["password"]
    step("3 onboard-system (device certificate)", **system.store(response["certificateChain"]),
         authenticationMethod=response["authenticationMethod"])

    # 4. log in as the system: the identity token is bound to the system certificate
    _, login = call(f"{AUTHENTICATION}/authentication/identity/login", system.cert_file, system.key_file,
                    {"systemName": SYSTEM, "credentials": {"password": password}})
    token = login["token"]
    step("4 identity-login (system certificate)", expirationTime=login.get("expirationTime"))

    # 5. register the system (hosted on the device) and its service
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Service)
    server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); server_ctx.load_cert_chain(system.cert_file, system.key_file)
    server_ctx.load_verify_locations(CA_CERT); server_ctx.verify_mode = ssl.CERT_REQUIRED
    server.socket = server_ctx.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    _, registered = call(f"{REGISTRY}/serviceregistry/system-discovery/register", system.cert_file, system.key_file,
                         {"version": "1.0.0", "addresses": [HOST], "deviceName": DEVICE,
                          "metadata": {"onboardedBy": "Onboarding", "role": "demo-sensor"}}, token=token)
    _, service = call(f"{REGISTRY}/serviceregistry/service-discovery/register", system.cert_file, system.key_file, {
        "serviceDefinitionName": "demoMeasurement", "version": "1.0.0", "expiresAt": None, "metadata": {"unit": "1"},
        "interfaces": [{"templateName": "generic_https", "protocol": "https", "policy": "CERT_AUTH", "properties": {
            "accessAddresses": [HOST], "accessPort": PORT, "basePath": "/demo",
            "operations": {"latest": {"method": "GET", "path": "/latest"}}}}]}, token=token)
    step("5 systemDiscovery and serviceDiscovery register", system=registered.get("name"),
         device=(registered.get("device") or {}).get("name"), service=service.get("instanceId"))

    # 6. consume a service through orchestration: store a measurement in the DataManager historian
    _, orchestration = call(f"{ORCHESTRATOR}/serviceorchestration/orchestration/pull", system.cert_file, system.key_file, {
        "serviceRequirement": {"serviceDefinition": "dataHistorian", "operations": ["put-data"], "versions": ["1.0.0"],
                               "interfaceTemplateNames": ["generic_https"], "securityPolicies": ["CERT_AUTH"]},
        "orchestrationFlags": {}}, token=token)
    selected = orchestration["results"][0]
    properties = selected["interfaces"][0]["properties"]
    operation = properties["operations"]["put-data"]
    path = operation["path"].replace("{systemName}", SYSTEM).replace("{serviceName}", "demoMeasurement")
    endpoint = f"https://{properties['accessAddresses'][0]}:{properties['accessPort']}{properties['basePath']}{path}"
    value = round(20 + 5 * (time.time() % 1), 2)
    Service.latest = {"n": "demo", "v": value}
    call(endpoint, system.cert_file, system.key_file,
         [{"bn": f"urn:arrowhead:{DEVICE}:{SYSTEM}:", "bt": time.time(), "n": "temperature", "u": "Cel", "v": value}],
         method=operation["method"], token=token)
    step("6 orchestration pull dataHistorian and put-data", provider=selected.get("providerName"), value=value)

    if OFFBOARD:
        _, report = call(f"{ONBOARDING}/onboarding/device/offboard", device.cert_file, device.key_file, {})
        step("7 offboard-device (device certificate)", completed=len(report["completed"]), failed=report["failed"])
        try:
            call(f"{AUTHENTICATION}/authentication/identity/login", system.cert_file, system.key_file,
                 {"systemName": SYSTEM, "credentials": {"password": password}})
            step("8 identity-login after off-boarding", result="UNEXPECTEDLY ACCEPTED")
            summary["result"] = "failed"
        except (RuntimeError, ssl.SSLError, urllib.error.URLError) as error:
            # refused by Authentication, or already in the TLS handshake: the system certificate is revoked (CRL, J4)
            step("8 identity-login after off-boarding", result="refused", detail=str(error)[:160])
    summary.setdefault("result", "passed")
    print("SUMMARY " + json.dumps(summary), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        summary["result"] = "failed"; summary["error"] = str(error)
        print("SUMMARY " + json.dumps(summary), flush=True)
        sys.exit(1)
