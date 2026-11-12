# SPDX-License-Identifier: EPL-2.0
"""Host-side HTTPS client of the Rust test cloud v5.3.0 (operator and test identities only; never prints secrets)."""
from __future__ import annotations

import json
import pathlib
import ssl
import subprocess
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
INV = json.loads((ROOT / "inventory.json").read_text())
SYSTEMS = {s["role"]: s for s in INV["systems"]}
CA = str(ROOT / "secrets/ca.pem")
TOKENS: dict[str, str] = {}
_CTX: dict[str, ssl.SSLContext] = {}


def context(identity: str | None) -> ssl.SSLContext:
    if identity not in _CTX:
        ctx = ssl.create_default_context(cafile=CA)
        if identity:
            d = ROOT / "secrets" / identity
            ctx.load_cert_chain(str(d / "cert.pem"), str(d / "key.pem"))
        _CTX[identity] = ctx
    return _CTX[identity]


def request(role, method, path, body=None, identity="sysop", token=None, headers=None, timeout=15):
    hdr = {"Content-Type": "application/json"}
    selected = TOKENS.get(identity) if token is None else token
    if selected:
        hdr["Authorization"] = "Bearer IDENTITY-TOKEN//" + selected
    hdr.update(headers or {})
    url = f"https://127.0.0.1:{SYSTEMS[role]['hostPort']}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=hdr, method=method)
    try:
        with urllib.request.urlopen(req, context=context(identity), timeout=timeout) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as r:
        status, raw = r.code, r.read()
    try:
        return status, json.loads(raw)
    except (ValueError, UnicodeError):
        return status, raw.decode(errors="replace")


def login(identity: str, name: str) -> None:
    password = (ROOT / "secrets" / identity / "password").read_text().strip()
    code, body = request("authentication", "POST", "/authentication/identity/login",
                         dict(systemName=name, credentials=dict(password=password)), identity=identity, token="")
    if code != 200:
        raise SystemExit(f"login {name}: HTTP {code}")
    TOKENS[identity] = body["token"]


def console_password() -> str:
    return subprocess.run(["security", "find-generic-password", "-s", INV["keychainService"], "-w"],
                          capture_output=True, text=True, check=True).stdout.strip()
