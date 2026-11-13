# Java test cloud v5.3.0, 2026-11-11

This folder deploys the local Java test cloud from `Eclipse-Arrowhead-java` (primary source, `main` at `eb369d2a`). It
replaces the 5.2 cloud of `OLD/Arrowhead/Arrowhead-test-cloud-java` (Compose project `arrowhead-v52-test-cloud`), which
was taken down with `docker compose down`; its 42 volumes are kept, and it can be started again from that folder.

| | |
|---|---|
| Compose project | `arrowhead-v53-test-cloud` (48 services, 23 volumes) |
| Cloud | `TestCloud.Company.arrowhead.eu`, with a new cloud CA created 2026-11-11 (SHA-256 `D6:A6:23:09:…:E0:BB:C8`) |
| Console | http://testcloud.localhost:8490 (loopback), password in the macOS keychain, service `arrowhead-console-arrowhead-v53-test-cloud` (`make console-password`) |
| Images | `arrowhead-java-v530/*:20261111-v530`, built by `v530/build.py` from the primary tree; brokers and RandomDataProducer unchanged |
| Federation | none: no relay peers, neighbours or organisation cross-certificate |

## Files

- `base-compose.json`: the 5.2 cloud's definition of the core systems, their databases, the brokers and
  RandomDataProducer, with paths and project name rewritten for this folder. `generate.py` keeps only these services.
- `generate.py` -> `compose.json`, installed as `../compose.yaml`: each support system as its primary folder defines it,
  joined to this cloud (see the code for the mapping). Differences from the 2026-11-09 generator: own project, image
  registry and tag, no peer CRLs or neighbours, Gatekeeper with `GATEKEEPER_RELAY_ENABLED=false`, RandomDataProducer
  with `INTERCLOUD_ENABLED=false`, and LocalCloudConfigurator with this cloud's catalog (below).
- `build.py`: all images. Results in `build-results.json` and `build-logs/`.
- `prepare.py`: after `scripts/init.sh` and `scripts/generate-x509.sh`, every secret of `compose.json` (`.env`,
  `secrets/`), TLS certificates for all 20 databases, certificates of LocalCloudManager and LocalCloudConfigurator, and
  the PKCS#12 stores in `../security/primary-stores/<System>/`.
- `deploy.sh up|down`: bootstrap order, identities and policies (as `make up`, without `configure-intercloud.sh`).
- `localcloud-catalog/javacloud.json`: the primary catalog with `composeProject` set to this cloud's project. The
  primary catalog names `arrowhead-v52-test-cloud`, so the configurator and its host worker would otherwise act on the
  old project. The API reads it through `LCC_CATALOG_FILE`. The worker was installed with
  `install-direct.py --catalog` (primary tree), because both must use the same file.

## Relay identity without federation

Gatekeeper and GateTunnel load a relay key, chain and organisation CA when they start. With no organisation PKI, this
cloud's own CA stands in: `security/x509/org-ca.crt` is a copy of `ca.crt`, `*-relay-chain.crt` is the relay
certificate (from `generate-x509.sh`) followed by `ca.crt`, and the relay CRL is this cloud's CRL (`/org-crl/ca.crl`).
No other cloud trusts these identities, and the shared relay (`OLD/Arrowhead/Arrowhead-relay`) is unchanged. To federate
later, run the relay project's `generate-org-pki.sh` for this cloud and remove these stand-ins.

## Order used

```sh
cp v530/compose.json compose.yaml        # after python3 v530/generate.py
./scripts/init.sh                        # .env, random secrets, console password to the keychain
./scripts/generate-x509.sh               # new cloud CA (security/ca), system certificates, bundles, CRLs
# relay stand-ins (above), then ./scripts/make-credential-bundles.sh
python3 v530/prepare.py
python3 v530/build.py
./v530/deploy.sh up
```

Then the LocalCloudConfigurator host worker: a `LocalCloudConfiguratorWorker` certificate from this CA in
`~/.local/share/JavaLocalCloudConfigurator/certs` (the 5.2 cloud's worker credentials are kept as `*.before-v530`), and
`install-direct.py --cloud-dir <this folder> --compose-file <this folder>/compose.yaml --crl-file security/crl/ca.crl --catalog v530/localcloud-catalog/javacloud.json`.

## Release 5.3.0 images (2026-11-12)

The cloud now runs the qualified 5.3.0 release images of `Eclipse-Arrowhead-java` (commit `7c6ac61c` since
2026-11-13, before `b7c685e7`, `4ac53157`, `f1103ac9`, `d25225ae` and `02b4b4e2`; `verification/release-5.3.0/manifest.json`) instead of
images built here, under the tag `20261113-r530f` (before `20261113-r530e`, `20261113-r530d`, `20261113-r530c`, `20261113-r530`, `20261112-r530`)
(`TAG` in `generate.py`). The `20261111-v530` images are kept; set `TAG` back, run `generate.py` and `deploy.sh up` to
return to them (the previous compose file is `compose.yaml.before-r530-20261112`).

```sh
python3 v530/use-release-images.py ../../Eclipse-Arrowhead-java/verification/release-5.3.0/manifest.json 20261112-r530
python3 v530/generate.py && ./v530/deploy.sh up
```

`use-release-images.py` tags the support images of the manifest under this cloud's names, builds `core-adapter/` on
the release core images, and writes `release-images.json`. The core database images are tagged from the release when
they are on MySQL 8.4 (since `f1103ac9`); for an earlier manifest, whose core database images were the upstream
`mysql:8.1` ones, it builds `core-db/` from the manifest commit instead. All 47 containers
of these images run the image IDs recorded there (checked after deployment). The brokers and RandomDataProducer are
unchanged.

- First `deploy.sh up`: LocalCloudManager and EventHandler exited at startup with "Invalid authorization header";
  both started on the next attempt, and the second `deploy.sh up` completed. Cause: at startup the common library
  logs in from the main thread and from its scheduled login job at nearly the same time (the job's `synchronized`
  does not cover both, as Quartz creates a job instance per run); the second token supersedes the first one while
  the registration call is under way. Intermittent; fixed on 2026-11-13 (below).
- `scripts/smoke-test.sh`: 14/14 OK.
- `scripts/smoke-security.sh`: passed, 194 checks, 0 failures; the relay checks are skipped without federation. Every
  check of the run on the `20261111-v530` images passes again; the 8 additional ones are the SoLC checks added since.

**2026-11-13, fixed release images (`20261113-r530`).** The login race is fixed in the common library
(`Eclipse-Arrowhead-java` `d25225ae`: one lock for all `OutsourcedLoginJob` instances) and the release was
requalified on that commit. Redeployed with `use-release-images.py <manifest> 20261113-r530` and `deploy.sh up`; the
previous compose file is `compose.yaml.before-r530b-20261113`, and both earlier tags are kept.

- `deploy.sh up` completed on the first attempt. Every one of the 22 Arrowhead systems logged in exactly once at
  start-up (before the fix: twice), and no container logged "Invalid authorization header".
- All 47 containers run the image IDs of `release-images.json`.
- `scripts/smoke-test.sh`: 14/14 OK. `scripts/smoke-security.sh`: passed, 194 checks, 0 failures, relay checks skipped.
- RandomDataProducer (unchanged demo image) was unhealthy for a few minutes while DataManager and the brokers were
  recreated, then published again.

**2026-11-13, release core database images (`20261113-r530c`).** `Eclipse-Arrowhead-java` `f1103ac9` moves the
release's five core database images to MySQL 8.4.13 (the recipe of `core-db/`), and the release was requalified on
that commit. Redeployed with `use-release-images.py <manifest> 20261113-r530c` and `deploy.sh up`; the previous compose
file is `compose.yaml.before-r530c-20261113`.

- The five core databases now run the release's own images (tagged, not rebuilt). Their volumes, initialised by
  MySQL 8.1 since 2026-11-11, were upgraded in place by MySQL 8.4.13 on first start; data and passwords kept.
- `deploy.sh up` completed on the first attempt; no container logged "Invalid authorization header".
- All 47 containers run the image IDs of `release-images.json`.
- `scripts/smoke-test.sh`: 14/14 OK. `scripts/smoke-security.sh`: passed, 194 checks, 0 failures, relay checks skipped.

**2026-11-13, core images non-root (`20261113-r530d`).** `Eclipse-Arrowhead-java` `4ac53157` makes the five core
application images run as UID/GID 10001 (Compose already ran them as 10001); `core-adapter/Dockerfile` now switches
back to that user after its root-only adjustments. Redeployed with `use-release-images.py <manifest> 20261113-r530d`;
the previous compose file is `compose.yaml.before-r530d-20261113`.

- The first two `deploy.sh up` runs stopped: DataManager exited at start-up with "Blacklist system is not available".
  ServiceRegistry's calls to the recreated Blacklist failed without opening a connection from 14:35:53 to 14:45:09 UTC
  (Docker's DNS TTL is 600 s) while Blacklist was up and reachable; afterwards the third `deploy.sh up` completed. See
  "stale host-name cache" in the release qualification record. Not caused by the user change.
- All 47 containers run the image IDs of `release-images.json`; the core images and processes are 10001.
- `scripts/smoke-test.sh`: 14/14 OK. `scripts/smoke-security.sh`: passed, 194 checks, 0 failures, relay checks skipped.

**2026-11-13, host-name cache fix (`20261113-r530e`).** `Eclipse-Arrowhead-java` `b7c685e7` makes the common
library's HTTP client reuse a resolved host name for at most 10 s (before: the DNS TTL, 600 s here). Redeployed with
`use-release-images.py <manifest> 20261113-r530e`; the previous compose file is `compose.yaml.before-r530e-20261113`.

- `deploy.sh up` completed on the first attempt; no system exited.
- All 47 containers run the image IDs of `release-images.json`.
- Reproduction: Blacklist recreated at 19:29:33 UTC with a new address (172.19.0.7 → 172.19.0.29; a placeholder
  container held the old one), ready at 19:29:44. ServiceRegistry logged one failed blacklist check at 19:29:36,
  while Blacklist was starting, and none in the following eight minutes. On `20261113-r530d` the same procedure gave
  failures until about 4.5 minutes after Blacklist was ready.
- `scripts/smoke-test.sh`: 14/14 OK. `scripts/smoke-security.sh`: passed, 194 checks, 0 failures, relay checks skipped.

**2026-11-13, qualityEvaluation authorization (`20261113-r530f`).** `Eclipse-Arrowhead-java` `7c6ac61c` makes
DeviceQoSEvaluator ask ConsumerAuthorization about every `qualityEvaluation` call (filter, sort); before, any
authenticated system could call it. `scripts/configure-deviceqosevaluator-policy.sh` (run by `deploy.sh up` and
`make up`) grants it to DynamicServiceOrchestration only; set `DEVICEQOSEVALUATOR_QUALITY_EVALUATION_CONSUMERS` (a JSON
list) to change that. Redeployed with `use-release-images.py <manifest> 20261113-r530f`; the previous compose file is
`compose.yaml.before-r530f-20261113`.

- `deploy.sh up` completed on the first attempt. All 47 containers run the image IDs of `release-images.json`.
- DeviceQoSEvaluator logs `DeviceQoSEvaluatorAuthorizationFilter is active`.
- `scripts/smoke-test.sh`: 14/14 OK. `scripts/smoke-security.sh`: passed, 200 checks, 0 failures, relay checks
  skipped. The new QE section checks the policy, a 403 for SmokeClient without a grant, a pass with a temporary
  grant, and that the grant is removed again.
- The orchestrator here runs with `enable.qos=false`, so an orchestration with QoS requirements
  (DynamicServiceOrchestration → DeviceQoSEvaluator) was not exercised end to end.

## Results (2026-11-11)

- `build.py`: 50 images PASS. 23 of the 24 Maven builds reused Docker's layer cache from the 2026-11-10 SOS-16
  builds of identical sources, so their tests were not run again here.
- `deploy.sh up`: all steps succeeded; all 48 containers run, all with a health check healthy.
- `scripts/smoke-test.sh`: 14/14 OK.
- Console: all read views 200 without upstream errors. Overview: 24 systems, 106 services, 0 incidents, CRL valid.
  LC view: catalog, status (48 running services) and plan review work. Apply of the default design (one step,
  `smoke verify-localcloud`) ran as deployment `local-4d3303aa-…`: success, "no services changed"; all 48 containers
  kept their start times.
  Start/stop through the LC view with SimpleOrchestration (not protected, no catalog dependents):
  - stop (`remove: [serviceorchestration-simple]`): plan `stop serviceorchestration-simple, stop
    serviceorchestration-simple-db, smoke`; deployment `local-03c1455d-…` success; both containers exited cleanly, the
    other 46 kept their start times, LC status 46 running.
  - start (SimpleOrchestration selected again): plan `up serviceorchestration-simple-db, up serviceorchestration-simple,
    smoke`; deployment `local-7aa8f63c-…` success; both healthy, SimpleOrchestration published its 6 services again,
    the console's orchestration rules view reaches it, LC status 48 running, `smoke-test.sh` OK, the other 46 untouched.
- `make smoke-security`: passed, 186 checks (`smoke-security.log`). Its relay checks are skipped without federation
  (`scripts/smoke-security.sh` runs them only when `security/x509/ca-cross.crt` exists).
