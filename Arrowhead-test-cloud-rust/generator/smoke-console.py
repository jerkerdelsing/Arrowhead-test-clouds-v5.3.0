#!/usr/bin/env python3
# SPDX-License-Identifier: EPL-2.0
"""Rust test cloud v5.3.0: LocalCloudManager console, logged in, every view the UI loads (app.js), plus the
login/Origin/Host guards. The password comes from the macOS keychain and is never printed; the session cookie is kept
in memory only. Result: generator/smoke-console-results.json."""
import datetime
import http.client
import json
import socket
import ssl

import ahlib as ah

LCM = ah.SYSTEMS["localcloudmanager"]
HOST, PORT = LCM["consoleHost"], LCM["consolePort"]
ORIGIN = f"https://{HOST}:{PORT}"
CTX = ssl.create_default_context(cafile=ah.CA)
RESULTS = []
SUMMARY = {}
VIEWS = ["/api/overview", "/api/service-registry-management", "/api/orchestration/rules",
         "/api/orchestration/policies", "/api/plantdescriptions", "/api/sysmonitor", "/api/sysmonitor/subscriptions",
         "/api/datamanager?limit=240", "/api/consumers", "/api/intercloud", "/api/logs?service=serviceregistry&tail=180"]


class Conn(http.client.HTTPSConnection):
    """Connects to 127.0.0.1 and verifies the certificate for the console host name (as a browser does for
    *.localhost)."""
    def connect(self):
        sock = socket.create_connection(("127.0.0.1", PORT), self.timeout)
        self.sock = CTX.wrap_socket(sock, server_hostname=HOST)


def call(method, path, body=None, cookie=None, origin=ORIGIN, host=f"{HOST}:{PORT}", extra=None):
    c = Conn(HOST, PORT, timeout=40)
    h = {"Host": host, "Content-Type": "application/json"}
    if origin:
        h["Origin"] = origin
    if cookie:
        h["Cookie"] = cookie
    h.update(extra or {})
    c.request(method, path, body=json.dumps(body) if body is not None else None, headers=h)
    r = c.getresponse()
    raw = r.read()
    try:
        data = json.loads(raw)
    except ValueError:
        data = raw.decode(errors="replace")
    return r.status, data, r.getheader("Set-Cookie") or ""


def check(label, passed, detail=""):
    RESULTS.append(dict(test=label, passed=bool(passed), detail=detail))
    print(("PASS " if passed else "FAIL ") + label + (f"  [{detail}]" if detail and not passed else ""), flush=True)


def problems(value, path=""):
    """Provider errors a view reports in its body (keys named error/errors/lastError/neighbourError with content)."""
    out = []
    if isinstance(value, dict):
        for k, v in value.items():
            if k in ("error", "errors", "neighbourError", "registryError", "dockerError", "lastError"):
                real = {kk: vv for kk, vv in v.items() if vv} if isinstance(v, dict) else v
                if real:
                    out.append(f"{path}/{k}={json.dumps(real)[:200]}")
            else:
                out += problems(v, f"{path}/{k}")
    elif isinstance(value, list):
        for i, v in enumerate(value[:50]):
            out += problems(v, f"{path}[{i}]")
    return out


def main():
    pw = ah.console_password()
    code, html, _ = call("GET", "/")
    check("console page served", code == 200 and "LocalCloudManager" in str(html), f"HTTP {code}")
    for asset in ("/app.js", "/styles.css"):
        check(f"{asset} served", call("GET", asset)[0] == 200)
    check("views need a login", call("GET", "/api/overview")[0] == 401)
    check("wrong password refused", call("POST", "/api/session", {"password": "wrong-" + pw[:0] + "x" * 20})[0] == 401)
    check("foreign Origin refused", call("POST", "/api/session", {"password": pw}, origin="https://evil.localhost:6490")[0] == 403)
    check("foreign Host refused", call("POST", "/api/session", {"password": pw}, host=f"127.0.0.1:{PORT}")[0] == 403)
    code, _, set_cookie = call("POST", "/api/session", {"password": pw})
    del pw
    check("login with the keychain password", code in (200, 204), f"HTTP {code}")
    cookie = set_cookie.split(";", 1)[0]
    check("cookie is __Host-, Secure, HttpOnly, SameSite=Strict",
          cookie.startswith("__Host-") and all(f in set_cookie for f in ("Secure", "HttpOnly", "SameSite=Strict")))
    for path in VIEWS:
        code, body, _ = call("GET", path, cookie=cookie)
        issues = problems(body) if code == 200 else []
        check(f"view {path} HTTP 200", code == 200, f"HTTP {code} {json.dumps(body)[:300]}")
        check(f"view {path} without provider errors", code == 200 and not issues, "; ".join(issues)[:600])
        if code == 200 and isinstance(body, dict):
            SUMMARY[path] = {k: (len(v) if isinstance(v, (list, dict)) else v) for k, v in body.items()
                             if not isinstance(v, str) or len(v) < 60}
        if path == "/api/overview" and code == 200:
            names = {s.get("name") for s in body.get("systems", [])}
            want = {s["name"] for s in ah.INV["systems"] if not s.get("broker")}
            check(f"overview lists all {len(want)} systems", want <= names, f"missing {sorted(want - names)}")
            check("manager registered (from the registry)", body.get("registration", {}).get("registered") is True)
    check("mutation without confirm header refused",
          call("POST", "/api/containers/timemanager/restart", cookie=cookie)[0] in (400, 403, 428))
    check("logout", call("DELETE", "/api/session", cookie=cookie)[0] in (200, 204))
    check("session gone after logout", call("GET", "/api/overview", cookie=cookie)[0] == 401)


if __name__ == "__main__":
    error = None
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        error = f"{type(exc).__name__}: {exc}"
        print("ERROR " + error)
    passed = sum(r["passed"] for r in RESULTS)
    failed = len(RESULTS) - passed
    (ah.ROOT / "generator/smoke-console-results.json").write_text(json.dumps(dict(
        time=datetime.datetime.now(datetime.timezone.utc).isoformat(), passed=passed, failed=failed, error=error,
        checks=RESULTS, views=SUMMARY), indent=2) + "\n")
    print(f"console: {passed} passed, {failed} failed" + (f", error {error}" if error else ""))
    raise SystemExit(1 if failed or error else 0)
