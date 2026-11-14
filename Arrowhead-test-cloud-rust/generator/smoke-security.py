#!/usr/bin/env python3
# SPDX-License-Identifier: EPL-2.0
"""Rust test cloud v5.3.0 security regression test (2026-11-12). The Go/Java v5.3.0 clouds' smoke-security.sh
adapted to this cloud's model (no .env, no Compose secrets; credentials as read-only files, nginx TCP edge):
  H1  console and Docker gateway: loopback only, relay admits only the host, manager admits only its relay,
      gateway needs its token, only the gateway holds the Docker socket
  H2  no default or shared credentials: secrets only in files (700/600), not in environment, configuration or
      compose.json; identities unique per system; console password only in the keychain (scrypt hash in the manager)
  H3  PKI and revocation: foreign CA and missing certificate refused on every listener (brokers included); a
      disposable identity issued by CertificateAuthority is accepted, revoked, then refused at TLS everywhere
      without restarts
  J   container hardening (non-root, read-only root, no capabilities, no-new-privileges, not privileged, limits) and
      network isolation (systems on internal networks only, no egress)
Operator identity only; never prints secrets. Result: generator/smoke-security-results.json."""
import base64
import datetime
import json
import os
import pathlib
import socket
import ssl
import stat
import subprocess
import tempfile
import time
import uuid
import warnings

import ahlib as ah

ROOT = ah.ROOT
PROJECT = ah.INV["project"]
IMAGE = "arrowhead-rust-v530/rust-systems:20261114-v540"
RESULTS = []


def check(section, label, passed, detail=""):
    RESULTS.append(dict(section=section, test=label, passed=bool(passed), detail=detail))
    print(("PASS " if passed else "FAIL ") + f"[{section}] {label}" + (f"  ({detail})" if detail and not passed else ""),
          flush=True)


def containers():
    ids = subprocess.check_output(["docker", "ps", "-aq", "--filter", f"label=com.docker.compose.project={PROJECT}"],
                                  text=True).split()
    return json.loads(subprocess.check_output(["docker", "inspect", *ids], text=True))


def svc(c):
    return c["Config"]["Labels"]["com.docker.compose.service"]


def in_container(network, args, entrypoint="curl", timeout=20):
    """Throw-away client container of this cloud's image on one network (no credentials mounted)."""
    for attempt in range(2):  # one retry: a transient curl timeout (exit 28) is not a security result
        r = subprocess.run(["docker", "run", "--rm", "--network", network, "--entrypoint", entrypoint, IMAGE, *args],
                           capture_output=True, text=True, timeout=timeout + 10)
        if r.returncode != 28:
            break
    return r.returncode, (r.stdout + r.stderr).strip()


def tls_status(port, cert=None, key=None, path="/", host="127.0.0.1", server_name=None):
    """'http-<code>' when TLS was accepted, 'tls-refused' when the handshake or first read was refused."""
    ctx = ssl.create_default_context(cafile=ah.CA)
    ctx.check_hostname = server_name is not None
    if cert:
        ctx.load_cert_chain(cert, key)
    try:
        with socket.create_connection((host, port), timeout=8) as raw, \
                ctx.wrap_socket(raw, server_hostname=server_name or "localhost") as s:
            s.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode())
            data = s.recv(64)
            if not data:
                return "tls-refused"
            return "http-" + data.split(b" ")[1].decode() if data.startswith(b"HTTP/") else "tls-other"
    except (ssl.SSLError, ConnectionResetError, BrokenPipeError):
        return "tls-refused"
    except OSError as e:
        return f"os-{e.__class__.__name__}"


def broker_status(port, cert=None, key=None):
    """TLS handshake plus one read against a broker; brokers refuse a bad client certificate at the handshake."""
    ctx = ssl.create_default_context(cafile=ah.CA)
    ctx.check_hostname = False
    if cert:
        ctx.load_cert_chain(cert, key)
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=8) as raw, \
                ctx.wrap_socket(raw, server_hostname="localhost") as s:
            s.settimeout(3)
            # AMQP 0-9-1 protocol header; MQTT 3.1.1 CONNECT (clean session, client id "probe"), answered by CONNACK
            s.sendall(b"AMQP\x00\x00\x09\x01" if port == 6571 else
                      b"\x10\x11\x00\x04MQTT\x04\x02\x00\x3c\x00\x05probe")
            try:
                data = s.recv(16)
            except socket.timeout:
                return "accepted"
            if port != 6571:
                return "accepted" if data[:1] == b"\x20" and data[3:4] == b"\x00" else "tls-refused"
            return "accepted" if data else "tls-refused"
    except (ssl.SSLError, ConnectionResetError, BrokenPipeError):
        return "tls-refused"


def listeners():
    out = []
    for s in ah.INV["systems"]:
        if s.get("broker"):
            continue
        path = s.get("echo") or s.get("management") or ("/localcloud/monitor/echo" if s["role"] == "localcloudmanager"
                                                        else "/health")
        out.append((s["role"], s["hostPort"], path))
    return out


# ------------------------------------------------------------------------------------------------ sections
def exposure(cs):
    published = {}
    for c in cs:
        for target, binds in (c["HostConfig"].get("PortBindings") or {}).items():
            for b in binds or []:
                published.setdefault(svc(c), []).append((b.get("HostIp"), b.get("HostPort")))
    check("H1", "only edge and console-proxy publish ports", set(published) == {"edge", "console-proxy"},
          str(sorted(published)))
    allp = [p for v in published.values() for p in v]
    check("H1", f"all {len(allp)} published ports bind 127.0.0.1 only", all(ip == "127.0.0.1" for ip, _ in allp),
          str([p for p in allp if p[0] != "127.0.0.1"]))
    check("H1", "console published on 127.0.0.1:6490 only", published.get("console-proxy") == [("127.0.0.1", "6490")])
    sock = [svc(c) for c in cs if any(m.get("Source") == "/var/run/docker.sock" or
                                      m.get("Destination") == "/var/run/docker.sock" for m in c["Mounts"])]
    check("H1", "Docker socket only in manager-docker-proxy", sock == ["manager-docker-proxy"], str(sock))
    proxy = next(c for c in cs if svc(c) == "manager-docker-proxy")
    m = next(m for m in proxy["Mounts"] if m["Destination"] == "/var/run/docker.sock")
    check("H1", "Docker socket mounted read-only", not m["RW"])
    nets = {svc(c): set(c["NetworkSettings"]["Networks"]) for c in cs}
    check("H1", "Docker gateway only on the internal manager-control network",
          nets["manager-docker-proxy"] == {f"{PROJECT}_manager-control"}, str(nets["manager-docker-proxy"]))
    check("H1", "console network holds only the manager and its relay",
          {s for s, n in nets.items() if f"{PROJECT}_console" in n} == {"localcloudmanager", "console-proxy"})


def network_isolation(cs):
    n = json.loads(subprocess.check_output(["docker", "network", "inspect", f"{PROJECT}_arrowhead",
                                            f"{PROJECT}_manager-control"], text=True))
    check("J", "system and gateway networks are internal", all(x["Internal"] for x in n))
    nets = {svc(c): set(c["NetworkSettings"]["Networks"]) for c in cs}
    outside = [s for s, ns in nets.items() if s not in ("edge", "console-proxy", "localcloudmanager")
               and ns - {f"{PROJECT}_arrowhead", f"{PROJECT}_manager-control"}]
    check("J", "no system on a network with a route outside", not outside, str(outside))
    code, out = in_container(f"{PROJECT}_arrowhead", ["-s", "-o", "/dev/null", "--max-time", "5", "https://1.1.1.1/"])
    check("J", "no egress from the system network", code != 0, out[:120])
    code, out = in_container(f"{PROJECT}_arrowhead", ["-sk", "--max-time", "5", "http://manager-docker-proxy:8080/containers"])
    check("H1", "Docker gateway unreachable from the system network", code != 0, out[:120])
    code, out = in_container(f"{PROJECT}_arrowhead", ["-sk", "--max-time", "5", "https://localcloudmanager:8490/health"])
    check("H1", "manager console refuses a client on the system network", code != 0, out[:120])
    code, out = in_container(f"{PROJECT}_manager-control", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time",
                                                           "5", "http://manager-docker-proxy:8080/containers"])
    check("H1", "Docker gateway refuses a request without its token", out == "401", f"{code} {out[:80]}")
    code, out = in_container(f"{PROJECT}_manager-control", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time",
                                                           "5", "-H", "Authorization: Bearer " + "x" * 48,
                                                           "http://manager-docker-proxy:8080/containers"])
    check("H1", "Docker gateway refuses a wrong token", out == "401", f"{code} {out[:80]}")
    code, out = in_container(f"{PROJECT}_console", ["-sk", "--max-time", "5", "https://console-proxy:8490/health"])
    check("H1", "console relay refuses other containers (only the host gateway)", code != 0, out[:120])
    code, out = in_container(f"{PROJECT}_console", ["-sk", "--max-time", "5", "https://localcloudmanager:8490/health"])
    check("H1", "manager console refuses a container on its console network that is not the relay", code != 0, out[:120])


def hardening(cs):
    for c in cs:
        s, hc = svc(c), c["HostConfig"]
        user = c["Config"].get("User") or ""
        uid = user.split(":")[0]
        bad = []
        if uid in ("", "0", "root"):
            bad.append(f"user={user or 'root'}")
        if not hc.get("ReadonlyRootfs"):
            bad.append("writable root")
        if "ALL" not in (hc.get("CapDrop") or []) or hc.get("CapAdd"):
            bad.append(f"caps drop={hc.get('CapDrop')} add={hc.get('CapAdd')}")
        if "no-new-privileges:true" not in (hc.get("SecurityOpt") or []):
            bad.append("no no-new-privileges")
        if hc.get("Privileged") or hc.get("NetworkMode") == "host" or hc.get("PidMode") == "host":
            bad.append("privileged/host namespace")
        if not hc.get("Memory") or not hc.get("PidsLimit"):
            bad.append("no memory/pids limit")
        check("J", f"{s} hardened", not bad, "; ".join(bad))
    healthy = [svc(c) for c in cs if c["State"].get("Health", {}).get("Status") == "healthy"]
    check("J", f"all {len(cs)} containers healthy", len(healthy) == len(cs),
          str(sorted({svc(c) for c in cs} - set(healthy))))


def secrets_at_rest(cs):
    s = ROOT / "secrets"
    check("H2", "secrets/ is 700", stat.S_IMODE(s.stat().st_mode) == 0o700)
    loose = []
    for p in s.rglob("*"):
        if p.is_file() and p.name in ("key.pem", "password", "ca.key", "token-secret", "docker-token", "console.hash") \
                and stat.S_IMODE(p.stat().st_mode) & 0o077:
            loose.append(str(p.relative_to(ROOT)))
    check("H2", "private keys and passwords are 600", not loose, str(loose[:5]))
    values = {}
    for p in s.rglob("*"):
        if p.is_file() and p.name in ("password", "token-secret", "docker-token"):
            values[str(p.relative_to(ROOT))] = p.read_text().strip()
    check("H2", f"{len(values)} secret values are distinct", len(set(values.values())) == len(values))
    check("H2", "no secret shorter than 32 characters", all(len(v) >= 32 for v in values.values()))
    haystacks = {"compose.json": (ROOT / "compose.json").read_text(),
                 "config/*.json": "".join(p.read_text() for p in (ROOT / "config").glob("*.json")),
                 "container environment": json.dumps([c["Config"].get("Env") for c in cs]),
                 "container commands": json.dumps([[c["Config"].get("Cmd"), c["Config"].get("Entrypoint")] for c in cs])}
    for where, text in haystacks.items():
        leaked = [k for k, v in values.items() if v in text]
        check("H2", f"no secret value in {where}", not leaked, f"{len(leaked)} found")
    pw = ah.console_password()
    files = [p for p in ROOT.rglob("*") if p.is_file() and ".git" not in p.parts and p.stat().st_size < 2_000_000]
    in_files = [str(p.relative_to(ROOT)) for p in files if pw.encode() in p.read_bytes()]
    check("H2", "console password in no file of the cloud folder (keychain only)", not in_files, str(in_files[:3]))
    check("H2", "console password not in any container environment", pw not in haystacks["container environment"])
    del pw
    h = (ROOT / "secrets/localcloudmanager/console.hash").read_text().strip().split(":")
    check("H2", "manager holds only an scrypt hash of the console password",
          h[0] == "scrypt" and len(base64.b64decode(h[2])) == 32)
    auth = json.loads((ROOT / "config/authentication.json").read_text())
    names = [i["systemName"] for i in auth["bootstrapIdentities"]]
    check("H2", "one identity per system, only Sysop is sysop",
          len(names) == len(set(names)) and [i["systemName"] for i in auth["bootstrapIdentities"] if i.get("sysop")] == ["Sysop"])
    auth_c = next(c for c in cs if svc(c) == "authentication")
    ca_c = next(c for c in cs if svc(c) == "certificateauthority")
    others = [svc(c) for c in cs if svc(c) != "certificateauthority" and
              any(m["Source"].endswith("/secrets/ca.key") for m in c["Mounts"])]
    check("H2", "only CertificateAuthority holds the CA signing key", not others and
          any(m["Source"].endswith("/secrets/ca.key") for m in ca_c["Mounts"]), str(others))
    bootstrap = [svc(c) for c in cs if svc(c) != "authentication" and
                 any(m["Destination"].startswith("/run/bootstrap/") for m in c["Mounts"])]
    check("H2", "only Authentication holds the bootstrap passwords", not bootstrap and
          any(m["Destination"].startswith("/run/bootstrap/") for m in auth_c["Mounts"]))
    writable_trust = [svc(c) for c in cs if any(m["Destination"] == "/run/trust" and m["RW"] for m in c["Mounts"])]
    check("H3", "only CertificateAuthority can write the published CRL", writable_trust == ["certificateauthority"],
          str(writable_trust))


def pki(cs, tmp):
    foreign = tmp / "foreign"
    foreign.mkdir()
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", foreign / "ca.key", "-out",
                    foreign / "ca.pem", "-days", "2", "-subj", "/CN=Foreign CA"], check=True, capture_output=True)
    subprocess.run(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", foreign / "key.pem", "-out",
                    foreign / "req.pem", "-subj", f"/CN=Sysop.{ah.INV['suffix']}/dnQualifier=op"], check=True,
                   capture_output=True)
    subprocess.run(["openssl", "x509", "-req", "-in", foreign / "req.pem", "-CA", foreign / "ca.pem", "-CAkey",
                    foreign / "ca.key", "-set_serial", "7", "-days", "2", "-out", foreign / "cert.pem"], check=True,
                   capture_output=True)
    fc, fk = str(foreign / "cert.pem"), str(foreign / "key.pem")
    sc, sk = str(ROOT / "secrets/sysop/cert.pem"), str(ROOT / "secrets/sysop/key.pem")
    for role, port, path in listeners():
        check("H3", f"{role} accepts the operator certificate", tls_status(port, sc, sk, path).startswith("http-"))
        check("H3", f"{role} refuses no client certificate", tls_status(port, None, None, path) == "tls-refused")
        check("H3", f"{role} refuses a foreign-CA certificate with a valid-looking name",
              tls_status(port, fc, fk, path) == "tls-refused")
    for name, port in (("amqp-broker", 6571), ("mqtt-broker", 6883)):
        check("H3", f"{name} accepts a cloud certificate", broker_status(port, sc, sk) == "accepted")
        check("H3", f"{name} refuses no client certificate", broker_status(port) == "tls-refused")
        check("H3", f"{name} refuses a foreign-CA certificate", broker_status(port, fc, fk) == "tls-refused")
    # TLS versions: rustls has no TLS 1.0/1.1; check the server refuses them when this client can offer them
    warnings.simplefilter("ignore", DeprecationWarning)
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
        ctx.set_ciphers("DEFAULT:@SECLEVEL=0")
        ctx.minimum_version, ctx.maximum_version = ssl.TLSVersion.TLSv1, ssl.TLSVersion.TLSv1_1
        with socket.create_connection(("127.0.0.1", 6443), timeout=5) as raw, ctx.wrap_socket(raw):
            old = "accepted"
    except ssl.SSLError as e:
        old = "refused-by-server" if "PROTOCOL_VERSION" in str(e).upper() or "ALERT" in str(e).upper() else f"client:{e.reason}"
    if old.startswith("client:"):
        print(f"SKIP [H3] TLS 1.0/1.1 probe: this client cannot offer them ({old})")
    else:
        check("H3", "ServiceRegistry refuses TLS 1.0/1.1", old == "refused-by-server", old)
    crl = subprocess.run(["openssl", "crl", "-in", ROOT / "trust/current.crl.pem", "-noout", "-issuer", "-nextupdate"],
                         capture_output=True, text=True)
    check("H3", "published CRL is valid and issued by the cloud CA", crl.returncode == 0 and "Rust v5.3.0" in crl.stdout)
    # live revocation with a disposable identity issued by CertificateAuthority
    probe = tmp / "probe"
    probe.mkdir()
    name = "CrlProbe" + uuid.uuid4().hex[:8]
    subprocess.run(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", probe / "key.pem", "-out",
                    probe / "req.pem", "-subj", f"/CN={name}.{ah.INV['suffix']}"], check=True, capture_output=True)
    code, signed = ah.request("certificateauthority", "POST", "/certificate-authority/sign",
                              dict(encodedCSR=(probe / "req.pem").read_text(), profile="sy", addresses=["localhost"]),
                              token="")
    check("H3", f"CertificateAuthority issues a disposable identity (HTTP {code})", code == 201)
    if code != 201:
        return
    (probe / "cert.pem").write_text(ssl.DER_cert_to_PEM_cert(base64.b64decode(signed["certificateChain"][0])))
    pc, pk = str(probe / "cert.pem"), str(probe / "key.pem")
    accepted = [r for r, p, path in listeners() if tls_status(p, pc, pk, path).startswith("http-")]
    check("H3", f"disposable identity accepted by all {len(listeners())} listeners before revocation",
          len(accepted) == len(listeners()), str(sorted({r for r, _, _ in listeners()} - set(accepted))))
    started = {svc(c): c["State"]["StartedAt"] for c in containers()}
    code, _ = ah.request("certificateauthority", "DELETE", f"/certificate-authority/mgmt/certificates/{signed['id']}",
                         token="")
    check("H3", f"revocation accepted (HTTP {code})", code == 200)
    t0 = time.monotonic()
    still = [r for r, _, _ in listeners()]
    while still and time.monotonic() - t0 < 90:
        still = [r for r, p, path in listeners() if tls_status(p, pc, pk, path) != "tls-refused"]
        if still:
            time.sleep(3)
    check("H3", f"revoked identity refused at TLS by all listeners ({time.monotonic() - t0:.0f} s)", not still,
          str(still))
    check("H3", "no container restarted for the CRL update",
          started == {svc(c): c["State"]["StartedAt"] for c in containers()})


def console_relay():
    st = tls_status(6490, path="/health", server_name="rustcloud-v530.localhost")
    check("H1", "console reachable from the host through its relay (server-only TLS, cloud CA)", st == "http-200", st)
    st = tls_status(6480, path="/localcloud/monitor/echo")
    check("H1", "manager system API refuses clients without a certificate", st == "tls-refused", st)


def other_clouds_untouched():
    out = subprocess.check_output(["docker", "ps", "--format", '{{.Label "com.docker.compose.project"}}'], text=True)
    counts = {p: out.split().count(p) for p in ("arrowhead-v53-test-cloud-go",
                                                "arrowhead-v53-test-cloud", "arrowhead-v52-test-cloud-go")}
    check("J", f"other clouds still running {counts}", all(v > 0 for v in counts.values()))


def main():
    cs = containers()
    exposure(cs)
    network_isolation(cs)
    hardening(cs)
    secrets_at_rest(cs)
    console_relay()
    with tempfile.TemporaryDirectory(prefix="rust530-security-") as t:
        os.chmod(t, 0o700)
        ah.login("sysop", "Sysop")
        pki(cs, pathlib.Path(t))
    other_clouds_untouched()


if __name__ == "__main__":
    error = None
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        error = f"{type(exc).__name__}: {exc}"
        print("ERROR " + error)
    passed = sum(r["passed"] for r in RESULTS)
    failed = len(RESULTS) - passed
    (ROOT / "generator/smoke-security-results.json").write_text(json.dumps(dict(
        time=datetime.datetime.now(datetime.timezone.utc).isoformat(), project=PROJECT, passed=passed, failed=failed,
        error=error, checks=RESULTS), indent=2) + "\n")
    print(f"security: {passed} passed, {failed} failed" + (f", error {error}" if error else ""))
    raise SystemExit(1 if failed or error else 0)
