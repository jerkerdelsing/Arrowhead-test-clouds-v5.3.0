#!/usr/bin/env python3
# SPDX-License-Identifier: EPL-2.0
"""Rust test cloud v5.3.0 smoke test (from the RustDev cloud's smoke.py, 2026-11-12): every system over its loopback
port, identities, registration, discovery with authorization, both orchestrators, Blacklist, Configuration,
DataManager, SysMonitor, LocalCloudManager's system API, federation off. Operator and test identities only; never
prints passwords or tokens. Result: v530/smoke-results.json."""
import datetime
import json
import ssl
import time
import urllib.error
import urllib.request
import uuid

import ahlib as ah
from ahlib import request

RESULTS = []


def check(label, passed):
    RESULTS.append(dict(test=label, passed=bool(passed)))
    print(("PASS " if passed else "FAIL ") + label, flush=True)
    return passed


def call(label, role, method, path, body=None, expected=200, identity="sysop", token=None, headers=None):
    code, result = request(role, method, path, body, identity, token, headers)
    check(f"{label} (HTTP {code}, expected {expected})", code == expected)
    return result if code == expected else None


def rejects_without_certificate(port, path):
    ctx = ssl.create_default_context(cafile=ah.CA)
    try:
        urllib.request.urlopen(f"https://127.0.0.1:{port}{path}", context=ctx, timeout=5)
        return False
    except urllib.error.HTTPError:
        return False
    except (urllib.error.URLError, OSError):
        return True


def run():
    ah.login("sysop", "Sysop")
    ah.login("test-provider", "TestProvider")
    ah.login("test-consumer", "TestConsumer")
    check("operator and test identities log in", True)
    systems = [s for s in ah.INV["systems"] if s.get("management")]
    for s in systems:
        role = s["role"]
        if s["echo"]:
            r = call(role + " certificate echo", role, "GET", s["echo"], token="")
            check(role + " echo content", r == "Got it!")
        r = call(role + " authenticated management", role, "GET", s["management"])
        check(role + " implementation is Rust", isinstance(r, dict) and r.get("map", {}).get("implementation") == "Rust")
        call(role + " rejects declared identity", role, "GET", s["management"], token="",
             headers={"Authorization": "Bearer SYSTEM//Sysop"}, expected=401)
        check(role + " rejects missing client certificate",
              rejects_without_certificate(s["hostPort"], s["echo"] or s["management"]))
    call("ordinary identity denied registry management", "serviceregistry", "POST",
         "/serviceregistry/mgmt/systems/query", {}, identity="test-consumer", expected=403)
    call("identity token bound to its certificate", "serviceregistry", "POST", "/serviceregistry/system-discovery/lookup",
         {}, identity="test-provider", token=ah.TOKENS["sysop"], expected=401)
    expected = {s["name"] for s in ah.INV["systems"] if not s.get("broker")}
    registered = set()
    for _ in range(45):
        code, rows = request("serviceregistry", "POST", "/serviceregistry/mgmt/systems/query", {})
        if code == 200:
            registered = {r.get("name") for r in rows["entries"]}
            if expected <= registered:
                break
        time.sleep(2)
    check(f"all {len(expected)} systems registered (missing: {sorted(expected - registered)})", expected <= registered)
    if "TestProvider" in registered:
        check("TestProvider system registered (from an earlier run)", True)
    else:
        call("TestProvider system registration", "serviceregistry", "POST", "/serviceregistry/system-discovery/register",
             dict(version="5.3.0", addresses=["localhost"], metadata={"qualification": "smoke"}), expected=201,
             identity="test-provider")
    service = "rustSmoke" + uuid.uuid4().hex[:8]
    req = dict(serviceDefinitionName=service, version="1.0.0", interfaces=[dict(
        templateName="generic_https", protocol="https", policy="CERT_AUTH",
        properties=dict(accessAddresses=["test-provider"], accessPort=8443, basePath="/smoke",
                        operations={"read": {"method": "GET", "path": "/"}}))])
    call("provider service registration", "serviceregistry", "POST", "/serviceregistry/service-discovery/register", req,
         expected=201, identity="test-provider")
    lookup = dict(serviceDefinitionNames=[service])
    found = call("discovery before authorization", "serviceregistry", "POST", "/serviceregistry/service-discovery/lookup",
                 lookup, identity="test-consumer")
    check("unauthorized service hidden", found is not None and found["count"] == 0)
    grant = {"list": [dict(provider="TestProvider", cloud="LOCAL", targetType="SERVICE_DEF", target=service,
                           defaultPolicy=dict(policyType="WHITELIST", policyList=["TestConsumer"]))]}
    call("grant consumer authorization", "consumer-authorization", "POST",
         "/consumerauthorization/authorization/mgmt/grant", grant, expected=201)
    found = call("authorized discovery", "serviceregistry", "POST", "/serviceregistry/service-discovery/lookup", lookup,
                 identity="test-consumer")
    check("authorized service found", found is not None and found["count"] == 1)
    found = call("dynamic orchestration", "serviceorchestration-dynamic", "POST", "/serviceorchestration/orchestration/pull",
                 dict(serviceRequirement=dict(serviceDefinition=service, operations=["read"],
                                              interfaceTemplateNames=["generic_https"]),
                      orchestrationFlags={"MATCHMAKING": True}), identity="test-consumer")
    check("dynamic orchestration selects TestProvider",
          bool(found and found.get("results")) and found["results"][0]["providerName"] == "TestProvider")
    instance = f"TestProvider|{service}|1.0.0"
    call("simple-store rule", "serviceorchestration-simple", "POST",
         "/serviceorchestration/orchestration/mgmt/simple-store/create",
         {"candidates": [dict(consumer="TestConsumer", serviceInstanceId=instance, priority=1)]})
    found = call("simple orchestration", "serviceorchestration-simple", "POST", "/serviceorchestration/orchestration/pull",
                 dict(serviceRequirement=dict(serviceDefinition=service)), identity="test-consumer")
    check("simple orchestration selects the stored instance",
          bool(found and found.get("results")) and found["results"][0]["serviceInstanceId"] == instance)
    blocked = "Smoke" + uuid.uuid4().hex[:8]
    call("blacklist create", "blacklist", "POST", "/blacklist/mgmt/create",
         dict(entities=[dict(systemName=blocked, reason="v5.3.0 smoke")]), expected=201)
    found = call("blacklist query", "blacklist", "POST", "/blacklist/mgmt/query", dict(systemNames=[blocked]))
    check("blacklist record stored", found is not None and found["count"] == 1)
    data = "eyJydXN0Ijp0cnVlfQ=="
    call("configuration store", "configuration", "PUT", "/configuration/mgmt/config/TestProvider",
         dict(systemName="TestProvider", fileName="smoke.json", contentType="application/json", data=data))
    found = call("configuration read", "configuration", "GET", "/configuration/config/TestProvider")
    check("configuration round trip", found is not None and found["data"] == data)
    for role in ("gatekeeper", "gatetunnel"):
        found = call(role + " status", role, "GET", f"/{role}/mgmt/status")
        check(role + " federation is off (no relay configured)",
              isinstance(found, dict) and not found.get("relay", {}).get("configured", False))
    call("onboarding refuses the operator certificate on the device step", "onboarding", "POST", "/onboarding/device",
         {}, expected=403)
    call("sysmonitor reconciles authorised providers", "sysmonitor", "POST", "/sysmonitor/management/reconcile", {},
         expected=202)
    # RandomDataProducer -> DataManager (dataHistorian), published every 30 s
    names = []
    for _ in range(40):
        code, body = request("datamanager", "GET", "/datamanager/data-historian/systems")
        if code == 200:
            names = json.dumps(body)
            if "RandomDataProducer" in names:
                break
        time.sleep(3)
    check(f"RandomDataProducer data in the DataManager historian (HTTP {code})", "RandomDataProducer" in names)
    # LocalCloudManager system API: mTLS, sysop identity token
    for path, ident, tok, exp in [("/localcloud/management/status", "sysop", None, 200),
                                  ("/localcloud/management/systems", "sysop", None, 200),
                                  ("/localcloud/management/status", "test-consumer", None, 403),
                                  ("/localcloud/management/status", "sysop", "", 401),
                                  ("/localcloud/monitor/echo", "sysop", "", 200)]:
        call(f"localcloudmanager {path} as {ident}{' without token' if tok == '' else ''}", "localcloudmanager", "GET",
             path, identity=ident, token=tok, expected=exp)


if __name__ == "__main__":
    error = None
    try:
        run()
    except Exception as exc:  # noqa: BLE001 - reported below
        error = f"{type(exc).__name__}: {exc}"
        print("ERROR " + error)
    passed = sum(r["passed"] for r in RESULTS)
    failed = len(RESULTS) - passed
    report = dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(), project=ah.INV["project"],
                  passed=passed, failed=failed, error=error, checks=RESULTS)
    (ah.ROOT / "v530/smoke-results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"smoke: {passed} passed, {failed} failed" + (f", error {error}" if error else ""))
    raise SystemExit(1 if failed or error else 0)
