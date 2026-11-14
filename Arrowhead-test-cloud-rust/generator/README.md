# Rust test cloud v5.3.0, 2026-11-12

This folder deploys a new local Rust test cloud built from `Eclipse-Arrowhead-rust` (the primary source, `main` at
`a7d4b50`, plus one uncommitted fix listed below). It replaces the RustDev cloud (Compose project `arrowhead-v53-test-cloud-rust`,
`OLD/Arrowhead/Arrowhead-test-cloud-rust/candidate-native`, ports 105xx), which ran next to it until it was torn down
on 2026-11-12 at the user's request. Its containers and project networks were removed with `docker compose down`;
its files, images and the relay's `arrowhead-rust-federation-network` were kept. The removed containers' definitions
are in `OLD/Arrowhead/Arrowhead-test-cloud-rust/teardown-20261112/`.

| | |
|---|---|
| Compose project | `arrowhead-v530-test-cloud-rust` (27 services; state in bind directories under `state/`) |
| Cloud | `RustCloud.Company.arrowhead.eu`, with a new cloud CA created 2026-11-12 (`secrets/ca.pem`, 2 years; system certificates 1 year) |
| Host ports (loopback) | 64xx: each system's primary default port minus 2000 (6443 ServiceRegistry, 6444 Authentication, …). LocalCloudManager system API 6480 (mTLS), console 6490, RandomDataProducer 6500, AMQPS 6571, MQTTS 6883 |
| Console | https://rustcloud-v530.localhost:6490/ (loopback). The certificate is from the cloud CA (`secrets/ca.pem`), so the browser shows a warning unless you trust that CA. The password is in the macOS keychain, service `arrowhead-console-arrowhead-v530-test-cloud-rust`; `make console-password` prints it |
| Image | `arrowhead-rust-v530/rust-systems:20261112-v530`, one native arm64 image built by `generator/build.sh` from the primary tree. It contains `arrowhead-core`, `arrowhead-support`, `RandomDataProducer`, `LocalCloudManager` and `localcloudmanager-docker-proxy`. RabbitMQ 4.3.7, Mosquitto 2.0.22 and nginx 1.31.8 are pinned upstream images |
| Federation | none: no relay, peers or peer CRLs; intercloud is off in DynamicServiceOrchestration and RandomDataProducer |

## Model

The model follows the RustDev cloud. Each system has one JSON configuration (`config/<role>.json`). Credentials are
read-only files (`secrets/<role>/`). Authentication seeds every identity from `bootstrapIdentities`, including
LocalCloudManager, so provisioning never logs in as a system. The systems sit on an internal-only network. Nothing was
copied from RustDev or any other cloud: no keys, passwords, state or CA. Changes from RustDev:

- Every system listens on its primary default port (`LISTENING-PORTS.md`). In RustDev they all listened on 8443.
- **Edge:** an nginx stream proxy (TCP pass-through) publishes the 64xx ports. It is the only container on the system
  network that also has a network with a route outside. It replaces RustDev's socat image, which was not built from a
  primary source.
- **Console:** the primary Rust LocalCloudManager serves its HTTPS console itself; its TLS ends in the manager. The
  `console-proxy` relay (nginx stream) is on its own network with only the manager, and admits only the host, which
  is the network gateway 10.241.2.1. The manager admits only the relay (`consoleClients`), loopback and gateways.
  There is one console origin, `https://rustcloud-v530.localhost:6490`, so the cookie is not shared with other
  consoles on 127.0.0.1 or localhost.
- **Console password:** random. It is stored only in the keychain; the manager gets its scrypt hash
  (`secrets/localcloudmanager/console.hash`). RustDev kept the plain password in a file.
- **Policies:** `generator/configure.py` grants the local authorization policies through ConsumerAuthorization as Sysop.
  These are RustDev's LOCAL policies, minus federation-only and smoke-test entries.

## Files

| File | Purpose |
|---|---|
| `generator/build.sh`, `generator/Dockerfile` (+ `.dockerignore`) | Image from the primary tree. Results go to `build-results.tsv` and `build-logs/` |
| `generator/generate.py` | PKI, passwords, console password (keychain), CRL, manufacturer CA (Onboarding), `config/`, `compose.json`, `inventory.json`, `amqp/`, `mqtt/`, `edge/`. Idempotent: credentials and state are created only when missing |
| `generator/deploy.sh up\|down` | Starts the cloud in bootstrap order, then runs `configure.py`. `down` keeps credentials and state |
| `generator/smoke.py`, `generator/smoke-console.py`, `generator/smoke-security.py` | Tests (`make smoke`, `make smoke-console`, `make smoke-security`); results in `generator/*-results.json` |
| `generator/docker_proxy.rs.before-rust530-20261112` | Backup of the primary file changed below |
| `Makefile` | `build generate up down ps smoke smoke-security smoke-console test console-password` |

Order used:

```sh
./generator/build.sh
python3 generator/generate.py
./generator/deploy.sh up
python3 generator/smoke.py; python3 generator/smoke-console.py; python3 generator/smoke-security.py
```

`generate.py` rewrites `edge/*.conf`, but Compose does not recreate a container whose bind-mounted file changed.
After changing the edge configuration, run `docker compose -f compose.json restart edge console-proxy`.

## Results (2026-11-12)

- `build.sh`: PASS (`build-results.tsv`; the first build, before the fix below, also passed but its Docker gateway refused to start).
- `deploy.sh up`: 27 of 27 containers healthy.
- `smoke.py`: 150 passed, 0 failed. It covers every system's echo, management, implementation, declared-identity and
  missing-certificate checks; registration of all 22 systems; discovery hidden until authorized; both orchestrators;
  Blacklist; Configuration; RandomDataProducer data in DataManager; federation off; and LocalCloudManager's system API
  (sysop 200, other identity 403, no token 401).
- `smoke-console.py`: 36 passed, 0 failed. It logs in with the keychain password and checks all 11 console views
  (overview, registry, orchestration rules and policies, plant descriptions, SysMonitor and its subscriptions,
  DataManager, consumers, intercloud, logs): each answers 200 with no provider error. It also checks the login,
  Origin, Host, confirm-header and logout guards.
- `smoke-security.py`: 141 passed, 0 failed. Areas covered:
  - exposure: loopback only; the Docker socket only in the gateway;
  - network isolation, including no egress;
  - console relay and manager source filters;
  - Docker gateway token;
  - container hardening;
  - secrets at rest and not in environment or configuration;
  - foreign-CA and missing certificates refused on all 22 listeners and both brokers;
  - TLS 1.0/1.1 refused;
  - live revocation: a CertificateAuthority-issued identity was refused at TLS by all listeners right after revocation,
    with no restart.

## Primary-source change (Eclipse-Arrowhead-rust, uncommitted)

`ah5-LocalCloudManager-rust/src/docker_proxy.rs`: the Docker gateway refused to start unless `CANDIDATE_PROJECT` was
exactly `arrowhead-v53-test-cloud-rust`, RustDev's project name. It now accepts any valid Compose project name
(`valid_project`); it still serves only that one project's containers, matched exactly by label. New unit test:
`candidate_project_is_any_compose_project_name`. `cargo test --locked --workspace`: 177 passed, 0 failed (176
before). The changed file is rustfmt-clean and has no clippy findings; `cargo fmt --check` and
`clippy -D warnings` already failed elsewhere before this change (`ah5-core-rust` formatting, a
`collapsible_if` in `ah5-support-runtime-rust/src/choreography.rs`).

## Known gaps (primary source, not changed)


- LocalCloudManager registers itself as version `5.2.2` with metadata `qualification: candidate` (`secure.rs`), and the
  crate versions are still 5.2.2.
- The legacy, non-secure LocalCloudManager router (`localcloudmanager.rs`, not built into the `LocalCloudManager`
  binary) still names `TestCloud` and defaults the project to `arrowhead-v53-test-cloud-rust`.
- `ah5-LocalCloudManager-rust/tests/secure_console.rs` uses RustDev's project and port 10590 as fixtures. These are
  test data only.

## 5.4.0 development image (2026-11-14)

The cloud runs the image built from `Eclipse-Arrowhead-rust` `main` at `43b613f` (crate and reported versions 5.4.0;
the "still 5.2.2" gap above no longer applies), under the tag `20261114-v540` (`build.sh`, `generate.py`,
`smoke-security.py`). The `20261112-v530` image is kept; set the tag back, run `generate.py` and `deploy.sh up` to
return to it.

- `build.sh`: PASS. `generate.py` changed only the image tag in `compose.json`; credentials and state were kept.
- `deploy.sh up`: 27 of 27 containers healthy; the brokers, edge and console proxy were not recreated.
- `smoke.py`: 150 passed, 0 failed. `smoke-console.py`: 36 passed, 0 failed; the console reports release 5.4.0.
  `smoke-security.py`: 141 passed, 0 failed. Its live-revocation check adds an entry to `trust/current.crl.pem`.

**2026-11-14, folder rename.** `v530/` is now `generator/`; image, project and host names keep `v530`. Paths in the scripts,
compose definition and this file were updated, the cloud was redeployed with `generator/deploy.sh up`, and the smoke
and security checks passed again with the same counts. Earlier logs and result files keep the paths they recorded.
