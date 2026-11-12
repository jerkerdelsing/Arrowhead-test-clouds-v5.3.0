#!/usr/bin/env python3
# SPDX-License-Identifier: EPL-2.0
"""Rust test cloud v5.3.0: local authorization policies, granted by the operator identity Sysop through
ConsumerAuthorization (the LOCAL policies of the RustDev cloud without federation-only and smoke-test entries).
Idempotent: a grant replaces the policy of the same provider/target. Never logs in as a system."""
import sys
import time

import ahlib as ah

MONITORED = [s["name"] for s in ah.INV["systems"] if not s.get("broker")]


def policy(provider, target, default, scoped=None, description="Rust test cloud v5.3.0"):
    p = dict(provider=provider, cloud="LOCAL", targetType="SERVICE_DEF", target=target, description=description,
             defaultPolicy=dict(policyType="WHITELIST", policyList=default))
    if scoped:
        p["scopedPolicies"] = {k: dict(policyType="WHITELIST", policyList=v) for k, v in scoped.items()}
    return p


GRANTS = [policy(n, "sysMonitor", ["SysMonitor"]) for n in MONITORED] + [
    policy("SysMonitor", "sysMonitorData", ["AIGym"]),
    policy("SysMonitor", "sysMonitorHistory", ["LocalCloudManager"]),
    policy("DataManager", "dataHistorian", ["LocalCloudManager"],
           {"put-data": ["LocalCloudManager", "RandomDataProducer"], "get-data": ["LocalCloudManager"]}),
    policy("DynamicServiceOrchestration", "serviceOrchestration", ["RandomDataProducer"]),
    policy("ServiceRegistry", "deviceDiscovery", ["Onboarding"]),
    policy("ServiceRegistry", "serviceDiscovery", ["Onboarding"]),
    policy("ServiceRegistry", "systemDiscovery", ["Onboarding"]),
    policy("ConsumerAuthorization", "authorizationManagement", [], {"check-policies": ["Gatekeeper", "GateTunnel"]}),
    policy("Gatekeeper", "globalServiceDiscovery",
           ["DynamicServiceOrchestration", "SimpleStoreServiceOrchestration", "LocalCloudManager"]),
    policy("Gatekeeper", "interCloudNegotiation",
           ["DynamicServiceOrchestration", "SimpleStoreServiceOrchestration", "LocalCloudManager"]),
    policy("GateTunnel", "gateTunnelInterCloud", ["Gatekeeper"]),
    policy("GateTunnel", "gateTunnelConnection", ["Gatekeeper"]),
]


def main():
    for _ in range(60):
        try:
            if ah.request("authentication", "GET", "/authentication/monitor/echo", token="")[0] == 200:
                break
        except OSError:
            pass
        time.sleep(2)
    ah.login("sysop", "Sysop")
    code, body = ah.request("consumer-authorization", "POST", "/consumerauthorization/authorization/mgmt/grant",
                            {"list": GRANTS})
    if code != 201:
        print(f"grant failed: HTTP {code} {str(body)[:300]}", file=sys.stderr)
        raise SystemExit(1)
    print(f"{len(GRANTS)} local policies granted")


if __name__ == "__main__":
    main()
