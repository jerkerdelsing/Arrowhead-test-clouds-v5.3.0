# Go test cloud v5.3.0, 2026-11-11

This folder deploys a new local Go test cloud from `Eclipse-Arrowhead-go` (primary source, `main` at `018af5d`, clean
tree). It runs next to the 5.2 GoCloud (`OLD/Arrowhead/Arrowhead-test-cloud-go`, Compose project
`arrowhead-v52-test-cloud-go`, ports 9xxx), which is unchanged and still running.

| | |
|---|---|
| Compose project | `arrowhead-v53-test-cloud-go` (27 services, 25 volumes, 5 Compose secrets) |
| Cloud | `GoCloud.Company.arrowhead.eu`, with a new cloud CA created 2026-11-11 (SHA-256 `5F:EF:90:9B:…:FC:6D:C6`) |
| Host ports (loopback) | 74xx = the 84xx system ports (7443 ServiceRegistry, 7444 Authentication, …), AMQPS 7671, MQTTS 7883, RandomDataProducer 7500, console 7490 |
| Console | http://gocloud-v53.localhost:7490/ (loopback). Password in the macOS keychain, service `arrowhead-console-arrowhead-v53-test-cloud-go`; `make console-password` prints it |
| Images | `arrowhead-go-v530/*:20261111-v530`, 21 images built by `v530/build.sh` from the primary tree, native arm64; brokers, RandomDataProducer and the Docker proxy are unchanged 5.2 cloud images |
| Federation | none: `federationEnabled=false` in Gatekeeper and GateTunnel, no relay, neighbours or organisation PKI |

## What came from where

- From the 5.2 GoCloud folder (copied, not moved): `Makefile`, `scripts/`, `amqp/`, `mqtt/`, `security/*.ext`,
  `runtime/ServiceRegistry-go/application.properties`. Host ports, project name and console host name were rewritten
  (9xxx→7xxx, `arrowhead-v52-test-cloud-go`→`arrowhead-v53-test-cloud-go`, `gocloud.localhost`→`gocloud-v53.localhost`).
- Not copied: secrets, keys, certificates, `.env`, volumes. All were generated anew (`scripts/init.sh`, `scripts/generate-x509.sh`).
- `v530/base-compose.json`: the running 5.2 GoCloud's definition (`redeploy-20261110-sos16/go-compose.json`).
  `v530/generate.py` turns it into `../compose.yaml`. The copied 5.2 `compose.yaml` source is kept as
  `compose.yaml.before-go530-20261111`.
- The empty directories Docker had created here on 2026-11-05 (bind-mount placeholders, no files) were moved to
  `.stale-docker-mountpoints-before-go530-20261111/`.

## Changes against the 5.2 cloud

- **Console:** the 5.2 cloud's Node.js `cloud-monitor-api`/`cloud-monitor-ui` are not built from a primary source. They are
  replaced by the primary **LocalCloudManager-go**, with two pieces in this folder:
  - `v530/console/launcher` (`ah-lcm-launcher`): reads `AUTHENTICATION_PASSWORD` and `CONSOLE_PASSWORD_HASH` from
    secret files (J7; LocalCloudManager-go reads them only from its environment), and bridges its Docker Unix socket
    to the whitelisting `docker-proxy` (H1).
  - `v530/console/proxy/nginx.conf` (`console-proxy`, nginx 1.31.8): LocalCloudManager-go serves its console only
    with mTLS on 8480. The proxy is published on 127.0.0.1:7490 and uses its own client identity `ConsoleProxy`
    (no Arrowhead identity or grants). It redirects every other host name to `gocloud-v53.localhost` (J6).
  - `security/local-cloud-manager.ext` now also has `serverAuth` and SAN `localcloudmanager`. `generate-x509.sh` and
    `make-credential-bundles.sh` issue and bundle `console-proxy`.
- **Images:** `v530/health/Dockerfile` adds `ah-probe` (TCP health check), `ah-lcm-launcher`, and empty `/state` and
  `/data` directories owned by 65532. The primary images are `scratch` images, so new volumes would otherwise belong to root.
- **ServiceRegistry bootstrap** (`v530/bootstrap-serviceregistry.yaml`, used by `deploy.sh` only while the registry
  snapshot has no `identity` service): the primary Go Authentication registers itself with an identity token, which
  the registry can verify only through that registration. For that one step the registry runs with
  `AUTHENTICATION_POLICY=certificate` (mTLS CN) and without its MQTT API; then it is recreated as configured.
  No system's credentials are used by the operator.
- `scripts/make-go-runtime.sh`: `federationEnabled:false` for Gatekeeper and GateTunnel.
- `scripts/configure-console-edit-policies.py` (backup `*.before-go530-20261111`): it no longer rewrites the
  registry metadata of a self-registered Go LocalCloudManager. Otherwise the registry refuses that manager's periodic
  re-registration ("metadata is not matching").
- `scripts/smoke-security.sh` (backup `*.before-go530-20261111`): adapted as follows.
  - Console section: LocalCloudManager-go behind the proxy; Docker-proxy allowlist checked from a throw-away client on
    its internal network; the manager must refuse clients without a certificate.
  - J8 (versions): the console proxy's nginx and the Go version read from a deployed binary. The Mosquitto version
    is read from stderr, where it is printed.
  - Without federation: J5 checks that federation is off; the relay checks in H3 are skipped.
  - The relay checks run again once `security/x509/ca-cross.crt` exists, as in the Java v5.3.0 cloud.

## Order used

```sh
python3 v530/generate.py        # compose.yaml
./scripts/init.sh               # .env, random secrets, console password to the keychain
./scripts/generate-x509.sh      # new cloud CA, certificates, bundles, CRL
./scripts/make-go-runtime.sh    # runtime-go/*.json, security/bundles-go
./v530/build.sh                 # images (build-results.tsv, build-logs/)
./v530/deploy.sh up             # bootstrap, identities, policies (idempotent)
./scripts/smoke-test.sh; SMOKE_ALL=1 ./scripts/smoke-test.sh; ./scripts/smoke-security.sh
```

`./v530/deploy.sh down` removes the containers and keeps volumes, secrets and certificates. Do not use the copied
`make up`: it builds from the 5.2 source layout.

## Results (2026-11-11)

- `build.sh`: 21 of 21 images PASS (`build-results.tsv`; the first build before the helper-layer change is
  `build-results-first.tsv`).
- `deploy.sh up`: success on the fourth run. The earlier runs stopped on the ServiceRegistry bootstrap, the CA's
  read-only `/crl` and a script name; their logs are `deploy-run-*-failed.log`. All 27 containers healthy.
- `scripts/smoke-test.sh`: 13/13 OK; with `SMOKE_ALL=1`: 19/19 OK.
- `scripts/smoke-security.sh`: passed, 130 checks, 0 failures (`smoke-security.log`).
- Console: login, logout, host and Origin checks, and Docker access through the proxy all work.

## Known gaps (primary source, not changed here)

- Fixed 2026-11-11 in `Eclipse-Arrowhead-go/ah5-LocalCloudManager-go` (uncommitted; image rebuilt, only `localcloudmanager`
  redeployed): the console's registry, consumer, orchestration-rules and plant views queried `service-instances` with an
  empty filter (400); the DataManager, SysMonitor and plant views used paths the Go providers do not serve (404); the
  consumer and intercloud views named `TestCloud`. `generate.py` now also sets `AUTHORIZATION_URL` (HTTPS) for the
  policy view. Every console view answers 200 without provider errors; intercloud reports no relay, as intended.
- LocalCloudManager-go accepts a login body of any content type; cross-site posts are refused by the Origin check.
- After the launcher, the manager process still holds the two secrets in its own environment. They are not in the
  container configuration or in PID 1's environment, which is what `smoke-security.sh` checks.
- `ah5-LocalCloudConfigurator-go` is not deployed. It is a ColonyOS stack that pulls images from Docker Hub and needs a
  host executor.
