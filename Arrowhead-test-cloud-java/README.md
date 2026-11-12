# Arrowhead 5.2 local test cloud

Java support migration (2026-10-16): CertificateAuthority, Gatekeeper, GateTunnel
and SysMonitor now run natively in Java 21 from
`../ah5-support-java-spring/JavaSupportRuntime`, replacing their Python backends.
Their SQLite volumes, certificate bundles and HTTPS API ports are retained.
See `JAVA-SUPPORT-MIGRATION-2026-10-16.md` and the runtime README for tests,
rollback and explicit legacy-mTLS federation limitations. LocalCloudManager's
backend remains Node.js; this migration does not make that backend Java.

A Docker Compose deployment of an Eclipse Arrowhead 5.2 local cloud, pinned by default to the 5.2.2 security-fix release.

The default stack contains the mandatory operational core (ServiceRegistry, DynamicServiceOrchestration, ConsumerAuthorization, and Authentication), every support system released for 5.2 (Blacklist, TranslationManager, and DeviceQoSEvaluator), the v5.2.2 Onboarding microsystem, the Arrowhead 5.2.2 Java DataManager, and a v5.2.2 Gatekeeper compatibility microsystem. SimpleStoreServiceOrchestration remains an opt-in profile.

It also includes a LocalCloudManager microsystem with a management API/collector and a separately served graphical dashboard. The API registers `localCloudManagement` in ServiceRegistry and exposes a constrained container lifecycle interface; the browser-facing service never receives the Docker socket.

An X.509-secured `RandomDataProducer` publishes a cryptographically generated integer from 0 through 100 to DataManager every 30 seconds. It first obtains an identity token from Authentication, then asks DynamicServiceOrchestration for an authorized `dataHistorian` provider and sends the value with its `put-data` operation over the returned `generic_https`/`CERT_AUTH` interface.

DataManager is the Java implementation from `../ah5-support-java-spring/DataManager` (`dataProxy`, `dataHistorian`, and `sysMonitor`), with its own MySQL schema in `datamanager-db`. `make up` builds its jar offline with the local Maven image (`scripts/build-datamanager-jar.sh`). It authenticates callers with Authentication identity tokens, requires the client certificate to belong to the same system, and asks ConsumerAuthorization to verify every `dataProxy` and `dataHistorian` operation; `scripts/configure-datamanager-policies.sh` grants `put-data` to RandomDataProducer and SysMonitor and read access to LocalCloudManager. The cloud CA private key is mounted read-only into CertificateAuthority for real certificate/CRL signing; it must not be distributed to other systems or cloud backups.

GraphDBManager (`../../Eclipse-Arrowhead/ah5-GraphDBManager-java-spring`, added 2026-10-28) is a copy of DataManager that keeps its history in Ontotext GraphDB Free (`graphdbmanager-graphdb`, internal network `db-graphdbmanager`, GraphDB security on with its own user) instead of MySQL. It offers `graphDataProxy` and `graphDataHistorian` (DataManager's definitions are reserved for DataManager) plus `sysMonitor`, on port 8467. `make up-graphdbmanager` adds it to a running cloud and `make smoke-graphdbmanager` checks it end to end through orchestration; see its README for the RDF model, secrets and grants (`scripts/configure-graphdbmanager-policies.sh`).

`SysMonitor` implements the accompanying SysDD and IDDs. Two X.509-only brokers carry the monitoring traffic: the AMQP 0-9-1 broker `amqp-broker` (RabbitMQ) carries the `sysMonitor` observations of all systems, and the MQTT 5 broker `mqtt-broker` carries SysMonitor's normalized `sysMonitorData` output and the other intra-cloud MQTT traffic. SysMonitor stores the observations of all monitored microsystems itself: every validated observation is written to its own observation history in SQLite (volume `sysmonitor-data`, retention `SYSMONITOR_RETENTION_DAYS`, default 30 days) and is readable through the registered `sysMonitorHistory` service (`list-systems`, `query`, `latest`), which ConsumerAuthorization grants to LocalCloudManager (`scripts/configure-sysmonitor-policy.sh`). DataManager stores no `sysMonitor` data. SysMonitor also keeps the subscriptions of its `sysMonitorManagement` service and an outbox for the `sysMonitorData` republication, advertises its mTLS management API in ServiceRegistry, obtains Authentication identity tokens, and orchestrates the authorized `sysMonitor` services. Every core and support system publishes `sysMonitor` natively (see below); DataManager's `sysMonitor` replaces its v4.6 `echo` service; SysMonitor refreshes its authorized orchestration result every 30 seconds and binds its durable intake queue `SysMonitor.observations` to the routing keys of the selected observation types (see *Selective sysMonitor subscriptions*). RandomDataProducer continues to emit the baseline `power` observation.

## Orchestrated service consumption

No core or support system calls another system at a configured address (since 2026-10-19). Each system is configured
with the ServiceRegistry only; it looks up Authentication (`identity`) and the orchestrator (`serviceOrchestration`) there,
and requests every other service from DynamicServiceOrchestration, per operation, before calling it:

| Systems | Mechanism |
| --- | --- |
| Spring core and support systems | common library `http.collector.mode=ORCHESTRATION` (default). `http.collector.bootstrap.services` lists the ServiceRegistry lookups (`serviceDiscovery`, `systemDiscovery`, `deviceDiscovery`, `serviceRegistryManagement`, `generalManagement`, `identity`, `serviceOrchestration`); results are reused for `http.collector.orchestration.ttl` (300 s) |
| DynamicServiceOrchestration | also looks up ConsumerAuthorization's and Blacklist's services (`HTTP_COLLECTOR_BOOTSTRAP_SERVICES`): it cannot orchestrate what its own orchestration process calls. It orchestrates Gatekeeper and TranslationManager through itself |
| Authentication | also looks up `authorization` (`HTTP_COLLECTOR_BOOTSTRAP_SERVICES`, and the default in its `application.properties`) for the check of its management filter (`management.policy=authorization`, e.g. Onboarding's `identity-mgmt-create`). Authentication authenticates its own requests with an `AUTHENTICATOR-KEY` header that only the holders of its secret key (ServiceRegistry, ConsumerAuthorization) can verify; DSO cannot, and refused the orchestration request |
| CertificateAuthority, Gatekeeper, GateTunnel, SysMonitor (JavaSupportRuntime), AIGym | `consume()` / `orchestrate()`; `SERVICE_REGISTRY_URL` is the only endpoint setting (`AUTHENTICATION_URL` only overrides the lookup in tests) |
| LocalCloudManager API | `orchestratedRequest()`; DataManager, SysMonitor, PlantDescriptionEngine, SimpleStore, DSO history, ConsumerAuthorization, Gatekeeper/GateTunnel status and RandomDataProducer are orchestrated |

The orchestrator returns a provider only when ConsumerAuthorization grants the requesting system the operation, so
every dependency is an authorization policy: `scripts/configure-orchestration-dependency-policies.sh` (part of `make up`,
also `make configure-orchestration-dependency-policies`) declares the ones not owned by a system's own policy script.
A new system, or a new call between systems, needs its grant there (or in the provider's policy script). The
orchestration history (`serviceOrchestrationHistoryManagement`, console view *Orchestration*) shows every request.
GateTunnel registers its Gatekeeper-only relay-session endpoints as `gateTunnelConnection` operations `open-provider-session`
/ `open-consumer-session`; Gatekeeper and GateTunnel register `status` in their management services.

Not changed: the brokers (`amqp-broker`, `mqtt-broker`, `arrowhead-relay`) are not Arrowhead systems and stay configured;
the Python RandomDataProducer and device demo keep their configured ServiceRegistry, Authentication and orchestrator
addresses (they already orchestrate their providers).

## Native sysMonitor

Every core and support system publishes its own `sysMonitor` service: `echo`, `power` and `status` observations every 30 seconds to the AMQP topic exchange `arrowhead` of `amqp-broker` with routing key `TestCloud.sysmonitor.<System>.<serviceInstance>.<type>`, over mutual TLS under the system's own X.509 identity (SASL `EXTERNAL`: the broker user is the certificate CN). Messages are persistent and confirmed by the broker. Each offer is registered with `generic_amqps`, `CERT_AUTH` and metadata `publisherMode=native`; `scripts/register-amqp-interface-templates.sh` (part of `make up`) creates the `generic_amqp`/`generic_amqps` interface templates in the ServiceRegistry. No delegated publisher is deployed; the former `system-monitor-publisher` service was removed and `../ah5-support-java-spring/SysMonitorPublisher` is deprecated.

| Systems | Publisher |
| --- | --- |
| Authentication, ConsumerAuthorization, DynamicServiceOrchestration, SimpleStoreServiceOrchestration, Blacklist, TranslationManager, DeviceQoSEvaluator, Onboarding, DataManager, TimeManager, EventHandler, Configuration, Choreographer | Common-library `SysMonitorPublisher` (`../ah5-common-java-spring`, `sysmonitor.*` properties) |
| ServiceRegistry | the Java ServiceRegistry (rebuilt from `../ah5-core-java-spring/serviceregistry`) |
| Gatekeeper, GateTunnel, SysMonitor, CertificateAuthority | Native Java `JavaSupportRuntime` / RabbitMQ Java client |
| RandomDataProducer | `src/amqp_client.py` (pika); demo producer, outside core/support backend inventory |
| AIGym | RabbitMQ Java client |
| LocalCloudManager | `../ah5-support-java-spring/LocalCloudManager/api/src/sysmonitor.js` (amqplib) |

## Onboarding procedure

A new device enters the cloud with the Arrowhead 5.2.2 onboarding procedure (Bicaku et al., 2018; see
`../ah5-support-java-spring/Onboarding`). It starts with nothing but a manufacturer-issued bootstrap certificate:

1. **Operator** approves the device: `./scripts/onboarding-approve-device.sh Device1 security/x509/device1-bootstrap.crt DemoSensor`
   (fingerprint of the bootstrap certificate and the systems the device may host; Sysop, `onboardingManagement approve-device`).
   The operator grants the systems' service rights in ConsumerAuthorization as usual (DemoSensor may `put-data` at DataManager).
2. **Device**, with the bootstrap certificate: `POST /onboarding/certificate/csr` → onboarding certificate (`on`, 24 h).
3. With the onboarding certificate: `POST /onboarding/device` → device certificate (`de`); Onboarding registers the device.
4. With the device certificate, per system: `POST /onboarding/system` → system certificate (`sy`) and identity password.
5. **System**: Authentication `identity-login`, ServiceRegistry `systemDiscovery register` (with `deviceName`) and
   `serviceDiscovery register`, then orchestration and service use.
6. **Off-boarding**: `POST /onboarding/device/offboard` (device) or `POST /onboarding/mgmt/enrollments/Device1/offboard`
   (operator) removes system and device from the ServiceRegistry and the identities, revokes all certificates at the
   CertificateAuthority and blacklists the systems.

The CertificateAuthority signs every certificate; Onboarding holds no CA key. `scripts/configure-onboarding-policy.sh` grants
Onboarding exactly the operations it needs (CertificateAuthority signing, validation and revocation of its own certificates;
Authentication identity create/remove; Blacklist create/remove); the ServiceRegistry management whitelist and direct access
include Onboarding. `scripts/migrate-onboarding-db.sh` adds the enrollment tables to an existing Onboarding database.

`make smoke-onboarding-procedure` runs the whole procedure with the demo device (`device-demo/`, compose profile `demo`): it
holds only the bootstrap certificate of Device1 and the TestCloud CA certificate, onboards itself and DemoSensor, registers,
is orchestrated to DataManager and stores a measurement, then repeats the procedure and off-boards itself.

## AMQP broker for sysMonitor

`amqp-broker` (RabbitMQ 4.3.6, `amqp/rabbitmq.conf`) accepts only AMQPS with a client certificate of the cloud CA (port 5671 on the host, 5671 in the cloud network). The access list `amqp/acl` names, per certificate CN, the routing keys a system may publish and the binding keys it may bind its own queues with:

```
user DataManager.TestCloud.Company.arrowhead.eu
publish TestCloud.sysmonitor.DataManager.DataManager.#

user SysMonitor.TestCloud.Company.arrowhead.eu
subscribe TestCloud.sysmonitor.*.*.*
publish TestCloud.sysmonitor.SysMonitor.SysMonitor.*
```

`scripts/generate-amqp-definitions.py` turns it into `amqp/definitions.json` (users without passwords, permissions, topic permissions), which the broker loads at start. After a change run `make amqp-acl`, which regenerates the file and imports it into the running broker. A new system that publishes `sysMonitor` needs its entry here (see the new-system checklist).

## Selective sysMonitor subscriptions

SysMonitor's `sysMonitorManagement` service decides which of the found `sysMonitor` producers, and which of their observation types, SysMonitor receives:

| Operation | HTTP | Meaning |
| --- | --- | --- |
| `providers` | `GET /sysmonitor/management/providers` | Producers found by orchestration, their observation types, the subscribed types and where the selection comes from |
| `subscriptions` | `GET /sysmonitor/management/subscriptions` | Stored subscriptions, including those of producers not found at the moment |
| `subscribe` | `PUT /sysmonitor/management/subscriptions/{providerSystem}` | Body `{"observationTypes": ["echo","status"] \| ["*"], "enabled": true}`; `If-Match: <revision>` for optimistic locking |
| `unsubscribe` | `DELETE /sysmonitor/management/subscriptions/{providerSystem}` | Removes the subscription; the producer falls back to the default |
| `status`, `reconcile` | `GET /status`, `POST /reconcile` | Intake state (queue, bindings), forced re-orchestration |

Producers without a subscription follow `SYSMONITOR_DEFAULT_SUBSCRIPTION` (`all`, the default, or `none`). `"enabled": false` switches a producer off. SysMonitor binds its durable queue only to `<baseRoutingKey>.<type>` of the selected types (or `<baseRoutingKey>.*` for `["*"]`), so unselected observations never reach it; the applied bindings are stored, so a restart removes bindings that are no longer selected. The management operations are restricted to LocalCloudManager. In the dashboard, the **SM** view has the panel *Subscriptions to sysMonitor producers* with a checkbox per observation type and the actions *Subscribe*, *Off* and *Default*.


The released upstream Java images are patched with jars built against the local common library: `make jars` (run automatically by `make up` when a jar is missing) builds them offline with the Maven image and `java-patch/Dockerfile` copies each jar into its upstream image. Re-run `make jars` after changing the common library or a system. Systems without their own TLS store (ServiceRegistry, Blacklist, TranslationManager, DeviceQoSEvaluator) receive one from `scripts/generate-x509.sh` under `runtime/<System>/config/certificate`. The broker ACL (`mqtt/acl`) lets each system write only its own topic, and `scripts/configure-all-sysmonitor-policies.sh` grants SysMonitor the `sysMonitor` service of every system. The dashboard overview shows `sysMonitor.observe` with the native/delegated count.

## Database connections

The Java systems connect to their MySQL servers with MariaDB Connector/J over TLS with full verification
(`sslMode=verify-full&serverSslCert=/etc/arrowhead/db-tls/ca.crt` in each `SPRING_DATASOURCE_URL`). `scripts/generate-x509.sh`
issues every `*-db` service a server certificate signed by the cloud CA, with the compose host name as SAN, under
`security/x509/db/<host>/`; each server mounts it at `/etc/mysql/tls` and runs with `--require-secure-transport=ON`, so
unencrypted TCP connections are refused. The cloud CA is mounted read-only into each system at `/etc/arrowhead/db-tls/ca.crt`.
Health checks and local administration use the server's Unix socket and are unaffected.

### Credential bundles

No container mounts `security/x509`. `scripts/make-credential-bundles.sh` (run by `generate-x509.sh` and by
`../Arrowhead-relay/scripts/generate-org-pki.sh`) builds `security/bundles/<service>/` for each container. A bundle holds
only that container's own key and certificate or keystore, plus its trust anchors (`ca.crt`; for Gatekeeper and
GateTunnel also `org-ca.crt` and the relay key and chain). Compose mounts the bundle read-only at `/certs`.

The signing keys of the cloud CA, the onboarding CA chain and the test manufacturer CA are in `security/ca/` (owner-only),
apart from the system credentials in `security/x509` (J15); `generate-x509.sh` moves them there. No container mounts
`security/ca`. The cloud CA key `ca.key` reaches a container only in the `certificate-authority` bundle. The native core
systems of the interchangeability overlays (`interchangeability/compose.*.yaml`) mount bundles too
(`serviceregistry`, `authentication`, `consumerauthorization`, `serviceorchestration-dynamic`,
`serviceorchestration-simple`). `make smoke-security` (section J15) inspects the mounts of every running container,
whichever compose files started it. On Docker Desktop, file modes do not protect a
bind-mounted file, because every such file appears to belong to the container user, so the mount scope is the
protection. The Java systems use their own keystores under `runtime/<System>/config/certificate/`.

A new container that needs certificate files gets a `bundle` line in `make-credential-bundles.sh` and the mount
`./security/bundles/<service>:/certs:ro`.

### Secrets

There are no fixed default credentials. `scripts/rotate-secrets.sh` keeps random per-cloud values in `.env` (mode 600):
- the Authentication identity passwords (`AH_PW_<ABBR>`, Sysop: `ARROWHEAD_SYSOP_PASSWORD`);
- the database users, per database: its root (`AH_DB_ROOT_<DB>`) and its system's own user (`AH_DB_PW_<DB>`). There is
  no shared database user. Support systems' users have data access (SELECT, INSERT, UPDATE, DELETE) on their own schema only;
- one keystore password per system (`AH_STORE_PW_<ABBR>`), for its keystore and truststore; there is no shared store
  password (J7);
- Authentication's secret key and ConsumerAuthorization's cryptographer key;
- the hash of the console password (`CONSOLE_PASSWORD_HASH`). The password itself is not in `.env` but in the macOS
  keychain (service `arrowhead-console-<project>`); `make console-password` prints it.

**Secrets reach the containers only as files (J7).** `rotate-secrets.sh` writes one file per Compose secret to
`secrets/<KEY>` (directory 700, files 600), and Compose mounts each under `/run/secrets` of the containers that use it.
No secret is in a container's environment, so none shows in `docker inspect` or `/proc/<pid>/environ`:
- Spring systems import `/run/secrets` as a config tree (`SPRING_CONFIG_IMPORT=configtree:/run/secrets/`); their
  environment holds only references such as `SERVER_SSL_KEY_STORE_PASSWORD=${ah.store-password}`.
- The databases, the Java support runtime, the console and RandomDataProducer read `<NAME>_FILE`
  (e.g. `MYSQL_ROOT_PASSWORD_FILE=/run/secrets/db-root-password`). The databases start through `db/mysql-entrypoint.sh`,
  which runs the official entrypoint but starts `mysqld` without the passwords in its environment.

Each database is on its own internal network (`db-<system>`), which only its owning system joins, so no other container
can reach it (security finding J1). Compose refuses to start a service whose secret is missing. Scripts read the secrets through `scripts/lib-secrets.sh`.

| Command | Effect |
|---|---|
| `make secrets` | Adds missing values only. |
| `make rotate-secrets` | Replaces every value; the old `.env` is kept as `.env.previous`. |
| `scripts/rotate-secrets.sh files` | Rewrites `secrets/` from `.env` (`generate` and `rotate` do this too). |
| `scripts/rotate-secrets.sh forget-previous` | Deletes `.env.previous` once the rotated cloud is verified (`make smoke-security`). |

`make rotate-secrets` then changes the running cloud and recreates it in bootstrap order:
- each identity via `identity/change` with the system's own certificate (never a login);
- each database user via `ALTER USER` through the server socket;
- the keystores, rebuilt by `generate-x509.sh`, each with its system's own password.

A fresh database volume gets the core system's own password from `db/zz-arrowhead-system-user-password.sh`. A fresh
Authentication's Sysop default is replaced by `provision-authentication-identities.sh`.

### Console access

The LocalCloudManager console needs an operator login; there is no anonymous API.
- **Login.** The console password is stored in the container only as a salted scrypt hash, `CONSOLE_PASSWORD_HASH`.
  The session cookie is `HttpOnly` and `SameSite=Strict`, and lasts 8 hours. Five wrong passwords from one client
  lock that client's login for a minute, doubling with each further lock (at most 15 minutes); other clients are not
  affected. The login accepts only `application/json`, so a cross-site form cannot submit to it.
- **Own host name.** The console is `testcloud.localhost` (`CONSOLE_HOST`; browsers resolve `*.localhost` to the
  loopback address; for Safari add `127.0.0.1 testcloud.localhost` to `/etc/hosts`). Any other host name, including
  `127.0.0.1`, is redirected there, so the session cookie is never sent to the other clouds' consoles on 127.0.0.1.
  Requests whose `Host` or `Origin` is not that name are refused (`CONSOLE_ALLOWED_HOSTS`), which defeats DNS
  rebinding. The UI cannot be framed.
- **Network.** Only the host reaches the UI: `cloud-monitor-ui` is on the network `console` with the API alone. The API
  serves only requests that carry the UI's `CONSOLE_PROXY_SECRET`; other containers of the cloud network get 403.
- **Rights.** The console identity `LocalCloudManager` has only what the UI uses: registry and SimpleStore management,
  PlantDescriptionEngine, SysMonitor, DataManager, Gatekeeper and GateTunnel management. The policy scripts
  (`scripts/lib-policies.sh`) act as the operator `Sysop`, never as the console.
- **Docker access.** The API runs as the unprivileged user `node` and holds no Docker socket. It reaches Docker only
  through `docker-proxy` (`../ah5-support-java-spring/LocalCloudManager/docker-proxy`), on the internal network `console-docker`. The proxy forwards only:
  - the list of this project's containers;
  - their logs;
  - start, stop and restart of the services in `MANAGED_SERVICES`.

  Anything else (exec, create, images, other projects) gets 403.

### Certificate revocation

The CertificateAuthority publishes a CRL of its revocation register to `security/crl/ca.crl`:
- at start, after every revocation, and hourly;
- each CRL is valid 72 hours (`CRL_VALIDITY_HOURS`, J16). The relying parties fail closed on an expired CRL, so a stopped
  CA stops the whole cloud once the last CRL expires; 72 hours leave time to notice. The console reports an incident when
  less than 12 hours remain, and `make smoke-security` (section J16) requires at least 24.

`generate-x509.sh` writes an initial empty CRL, so the brokers can start before the CA. Enforcement:

| Relying party | How it picks up a new CRL |
|---|---|
| MQTT broker | `crlfile`; `mqtt/crl-watch.sh` reloads it with SIGHUP within 10 s |
| AMQP broker | `amqp/advanced.config` (`crl_check`, hash directory); read on every connection |
| Inter-cloud relay | CRLs of all clouds; reloaded within 10 s |
| Spring systems (core, support, Onboarding, AIGym) | Tomcat `certificateRevocationListFile` (`ARROWHEAD_SSL_CRL_FILE`, common-library `CrlRevocationConfig`); TLS reloaded within 30 s |
| CertificateAuthority, Gatekeeper, GateTunnel, SysMonitor | `CRL_FILE`; checked on every handshake, re-read when the file changes |
| LocalCloudManager console API (outbound) | `TLS_CRL_FILE`; agents rebuilt when the file changes |

A missing or expired CRL makes them refuse clients (fail closed).

`scripts/revoke-certificate.sh <cert.pem> [--offboard]` revokes any certificate of this cloud CA as Sysop, including
those from `generate-x509.sh`, and waits until the CRL lists it. New TLS handshakes with it then fail everywhere.
`--offboard` also closes the system's Authentication sessions and removes its identity, so its tokens stop working at
once; restart or stop its container to end established connections.

### Container hardening

Every container runs with a read-only root filesystem, no Linux capabilities, `no-new-privileges`, and memory and
process limits. All of them run as a non-root user except `docker-proxy` (root, no capabilities: the Docker Desktop
socket is root-only). Writable paths are named volumes and small tmpfs mounts (`/tmp`, `/app/logs` for the Java log
files, the MySQL socket directory). The core images contain their configuration; only the keystores in
`runtime/<System>/config/certificate` are mounted, read-only. Files under `runtime/<System>/config` other than
`certificate/` are not used.

`make smoke-security` checks console access, the absence of default credentials and revocation end to end.

## Requirements

- Docker Engine or Docker Desktop with Compose v2
- About 8 GB of free memory for the default stack
- `curl` for the smoke test

The upstream 5.2.2 images are published for `linux/amd64`. The Compose file pins that platform, allowing Docker Desktop to run them through emulation on Apple Silicon. Native amd64 Linux does not incur that overhead.

## Start the cloud

```sh
make init
```

`make init` creates `.env` (mode 600) with random secrets for this cloud (`scripts/rotate-secrets.sh generate`), then run:

```sh
make pull
make up
make smoke
```

Open the management dashboard at [http://testcloud.localhost:8490](http://testcloud.localhost:8490) (`CONSOLE_HOST`; `127.0.0.1:8490` redirects there). To build or update only the management microsystem, run `make up-monitor`.
The dashboard asks for the operator console password: `make console-password` prints it (from the macOS keychain; `.env` holds only its hash).
The HTML source is not a standalone application; if opened as a local file it redirects to the deployed dashboard so API telemetry remains available.

The dashboard opens on the **OR** view by default. Its first panel visualizes every stored route as a live consumer-to-service-to-producer flow with its priority, followed by the Simple Store rule editor. It reads live producers and systems from ServiceRegistry, offers consumers with a compatible interface template, requires a registered X.509 identity for `CERT_AUTH` producers, and revalidates the selection before creating a rule. Rule creation and removal use the LocalCloudManager identity; private keys and Arrowhead tokens stay in the management API. Run `make up-orchestration-manager` to deploy the rule store and rebuild the dashboard.

The **DM** view graphically plots numeric DataManager `dataHistorian` streams and lists recent SenML records. DataManager content is fetched server-side using the LocalCloudManager X.509 client certificate, so private keys are never exposed to the browser. The overview retains a live five-minute runtime activity graph and shows the secured DataManager-to-broker monitoring publication plus SysMonitor's orchestrated subscription.

The **PD** view edits the PlantDescriptionEngine's plant descriptions (`plantDescriptionManagement`): a list of the stored descriptions, and an editor with name, active flag and included descriptions, the plant's systems (system ID, registered system name, metadata) with their ports (port name, service definition, interface, consumer or producer, metadata), and the connections from a consumer port to a producer port with an optional priority. Registered systems, service definitions and interface templates are offered as choices; a JSON tab shows and accepts the complete request. *Save* creates or replaces the description, *Delete* removes it; the engine's validation errors are shown in the editor. An active description becomes an atomic DSO plant-rule snapshot through `serviceOrchestrationPlantManagement` (`query`, `replace`); no SimpleStore deployment is required for PDE. Managed scopes retain unavailable connections and restrict DSO candidates without bypassing authorization, blacklist, locks or interface checks. Lower priority selects the best surviving provider; inter-cloud fallback cannot escape the plant. Existing orchestration caches may delay visible changes. Existing databases require `scripts/migrate-dso-plant-rules-db.sh` before the upgraded DSO starts (integrated into `make up` and `make up-plantdescriptionengine`). See the PDE README for upgrade and legacy-rule cleanup. The PlantDescriptionEngine's management policy is a whitelist with LocalCloudManager (system operators are always allowed); every write needs the dashboard's action confirmation header.

The **SM** view reads `sysMonitorHistory` through the management API: the latest `echo`, `power` and `status` of every monitored microsystem, the number of stored observations and the retention period, a liveness chart and the recent observations of the selected system.

The messaging infrastructure cards on the overview (AMQP broker and MQTT broker) provide **Logs** and **Restart** actions. Restart requires an explicit browser confirmation and uses the manager API's constrained `mqtt-broker` lifecycle permission.

`make up` waits for all database health checks. The Arrowhead containers populate their default configuration and test certificates into `runtime/<System>/config` on their first start. API ports are exposed only on `127.0.0.1` by default; databases are not exposed to the host.

## Deployment variants

| Command | Systems added to the default stack |
| --- | --- |
| `make up` | None; dynamic orchestration plus all released support systems |
| `make up-onboarding` | Focused Onboarding cloud, its database, registry bootstrap, Authentication, and dashboard |
| `make up-simple` | SimpleStoreServiceOrchestration (port 8442) |
| `make up-auth` | Alias for the fully authenticated default stack |
| `make up-all` | Default stack plus SimpleStoreServiceOrchestration |

Dynamic and SimpleStore orchestration intentionally use separate databases and ports, so they can be tested side by side.

Authentication is enabled by default. `make up` creates local-CA identities, enables TLS 1.2/1.3 with mandatory client certificates, provisions system identities, and configures ConsumerAuthorization policies. DynamicServiceOrchestration, SimpleStoreServiceOrchestration, and ConsumerAuthorization run with `outsourced` authentication. The deployment also publishes ServiceRegistry's bootstrap management dependency through a private `generic_https`/`CERT_AUTH` interface and grants only DynamicServiceOrchestration access to it.

Every core and support system checks a certificate and an identity token: callers present a local-CA client certificate (mutual TLS) and an Arrowhead identity token of the same system. The token's system must equal the certificate CN (token-to-certificate binding in the common library, `TokenCertificateBinding`), so a stolen token is refused from any other certificate. Authentication binds `login`, `logout` and `change` to the certificate as well. ServiceRegistry uses the `outsourced` policy too. The one token-free call is the lookup of the `identity` service, because a system must find Authentication before its first login; it still needs the client certificate. Authentication itself authenticates to the registry with its HMAC authenticator key (`AUTHENTICATOR_SECRET_KEYS`). Management stays restricted by a whitelist. System certificates carry `dnQualifier=sy`. The operator certificate `security/x509/sysop.crt` (`dnQualifier=op`) belongs to the built-in `Sysop` identity, which the setup scripts use (`scripts/registry-auth.sh`). Authentication seeds a ServiceRegistry identity with the default password `123456`; `provision-authentication-identities.sh` replaces it with the configured one (`SR-test-52`). Liveness endpoints (`/authentication/monitor/echo`, `/onboarding/echo`, `/certificate-authority/health`) and Onboarding device enrollment, which uses an approved bootstrap certificate because a device has no identity yet, are the only token-free operations.

For a host-side mTLS check, use the generated LocalCloudManager identity:

```sh
curl --cacert security/x509/ca.crt \
  --cert security/x509/local-cloud-manager.crt \
  --key security/x509/local-cloud-manager.key \
  https://127.0.0.1:8444/authentication/monitor/echo
```

## Endpoints

| System | Default URL |
| --- | --- |
| ServiceRegistry | `https://127.0.0.1:8443` (mTLS) |
| DynamicServiceOrchestration mTLS API | `https://127.0.0.1:8441` |
| ConsumerAuthorization mTLS API | `https://127.0.0.1:8445` |
| Blacklist | `https://127.0.0.1:8464` (mTLS) |
| TranslationManager | `https://127.0.0.1:8465` (mTLS) |
| DeviceQoSEvaluator | `https://127.0.0.1:8472` (mTLS) |
| DataManager mTLS API (`dataProxy`, `dataHistorian`) | `https://127.0.0.1:8461` |
| GraphDBManager mTLS API (`graphDataProxy`, `graphDataHistorian`) | `https://127.0.0.1:8467` |
| TimeManager mTLS API (`time.get-time`) | `https://127.0.0.1:8463/timemanager/time` |
| EventHandler mTLS API (`eventPublish`, `eventSubscription`) | `https://127.0.0.1:8455/eventhandler` |
| Configuration mTLS API (`configuration`, `configurationProxy`, `configurationManagement`) | `https://127.0.0.1:8459/configuration` |
| Choreographer mTLS API (`choreographerSession`, `choreographerExecutor`, `choreographerManagement`) | `https://127.0.0.1:8457/choreographer` |
| RandomDataProducer mTLS status | `https://127.0.0.1:8500` |
| SysMonitor mTLS management API | `https://127.0.0.1:8475` |
| sysMonitor AMQP 0-9-1 over mTLS | `amqps://127.0.0.1:5671` |
| sysMonitorData MQTT 5 over mTLS | `mqtts://127.0.0.1:8883` |
| Gatekeeper 5.2.2 mTLS API | `https://127.0.0.1:8449` |
| GateTunnel 5.2.2 mTLS API | `https://127.0.0.1:8453` |
| SimpleStoreServiceOrchestration mTLS API (profile) | `https://127.0.0.1:8442` |
| Authentication mTLS API | `https://127.0.0.1:8444` |
| Onboarding HTTPS API | `https://127.0.0.1:8435/onboarding` |
| LocalCloudManager dashboard | `http://testcloud.localhost:8490` |

All systems use HTTPS with mandatory local-CA client certificates and register `generic_https` interfaces with policy `CERT_AUTH`, the framework default behind TLS since 2026-10-23 (some services still set `SERVICE_INTERFACE_POLICY: CERT_AUTH` explicitly). The orchestration APIs additionally require outsourced identity tokens and ConsumerAuthorization decisions. Onboarding also requires a client certificate: a device enrolls with an approved bootstrap certificate (test device `Device1`: `security/x509/device1-bootstrap.crt`, approved at run time with `scripts/onboarding-approve-device.sh`; see *Onboarding procedure*). The MQTT broker requires client certificates as well.

### TimeManager

TimeManager (`../ah5-support-java-spring/TimeManager`) provides the `time` service: `GET /timemanager/time` returns the current time, the time zone (`TIMEMANAGER_TIMEZONE`, default `Europe/Stockholm`) and whether the time is trusted, which it decides by comparing its clock with `TIMEMANAGER_NTP_SERVERS` (default `pool.ntp.org,time.cloudflare.com`; the containers need outbound UDP 123). It runs with mTLS and Authentication identity tokens (identity `TimeManager`, `scripts/provision-timemanager-identity.sh`), registers through the bootstrap proxy on port 8511, re-registers its HTTP offers as `CERT_AUTH`, and keeps only its log in `timemanager-db`. `scripts/configure-timemanager-policy.sh` grants `time` to LocalCloudManager, RandomDataProducer, SysMonitor and AIGym (override with `TIMEMANAGER_TIME_CONSUMERS`) and its `sysMonitor` to SysMonitor. Its native `sysMonitor` `echo` is `degraded` while the time is not trusted. Host port: `TIMEMANAGER_PORT` (8463).


### EventHandler

EventHandler (`../ah5-support-java-spring/EventHandler`) provides publish-subscribe messaging: `eventPublish` (`POST /eventhandler/event-publish/publish`), `eventSubscription` (`POST /eventhandler/event-subscription/subscribe`, `DELETE .../unsubscribe/{id}`), `eventHandlerManagement`, `generalManagement` and native `sysMonitor`, with its own TLS MySQL database `eventhandler-db`. Like every system it requires mutual TLS plus an identity token bound to the client certificate. ConsumerAuthorization decides each publish, subscribe and unsubscribe (`scripts/configure-eventhandler-policy.sh`; publishers default to LocalCloudManager, RandomDataProducer, SysMonitor and PlantDescriptionEngine, subscribers to LocalCloudManager, RandomDataProducer, SysMonitor and AIGym; override with `EVENTHANDLER_PUBLISHERS` / `EVENTHANDLER_SUBSCRIBERS`). Notifications are POSTed to the subscriber's notify URI with the EventHandler certificate and identity token, so the notify URI must be an HTTPS (mutual TLS) endpoint; a plain HTTP notify URI is rejected with 400. Management is `sysop-only`. `make up-eventhandler` deploys it on its own.
### Configuration

Configuration (`../ah5-support-java-spring/Configuration`) stores one configuration file per system. A system reads its own file through `configuration` (`GET /configuration/config`, or `/configuration/config/raw` for the file with its media type); `configurationProxy` lets a granted system read and store files on behalf of other systems; `configurationManagement` (`/configuration/mgmt/config`) is sysop-only. It runs with mTLS and Authentication identity tokens (identity `Configuration`, `scripts/provision-configuration-identity.sh`), registers through the bootstrap proxy on port 8512, re-registers its HTTP offers as `CERT_AUTH`, and keeps the files in `configuration-db` (maximum size `CONFIGURATION_MAX_SIZE`, 1 MiB). `scripts/configure-configuration-policy.sh` grants `configuration` to LocalCloudManager, RandomDataProducer, SysMonitor, AIGym, TimeManager and DataManager (override with `CONFIGURATION_CONSUMERS`), `configurationProxy` to LocalCloudManager (`CONFIGURATION_PROXIES`) and its `sysMonitor` to SysMonitor. Host port: `CONFIGURATION_PORT` (8459).

### Choreographer

Choreographer (`../ah5-support-java-spring/Choreography`) runs workflow plans (actions of steps) by starting executor systems. For each step it lets DynamicServiceOrchestration orchestrate the step's service requirement *for the executor* through `serviceOrchestrationPushManagement`; DSO pushes the result to `POST /choreographer/orchestration-result/{id}`, which accepts only DSO's certificate and pending ids. Plans, executors and sessions are managed through `choreographerManagement` (`/choreographer/mgmt`, sysop-only); clients start sessions by plan name with `choreographerSession`; executors register and report step results with `choreographerExecutor` and offer `POST <basePath>/service-info`, `/start` and `/abort`. It runs with mTLS and Authentication identity tokens (identity `Choreographer`, `scripts/provision-choreographer-identity.sh`), registers through the bootstrap proxy on port 8513, re-registers its HTTP offers as `CERT_AUTH`, is listed in ServiceRegistry `service.discovery.direct.access` (it looks up providers for `check-plan`), and keeps its plans, executors, sessions and worklog in `choreographer-db` (`--innodb-use-native-aio=0`: the many MySQL servers of the clouds exhaust the kernel AIO limit). `scripts/configure-choreographer-policy.sh` grants it DSO `serviceOrchestrationPushManagement`, grants `choreographerSession` to `CHOREOGRAPHER_SESSION_CLIENTS` and `choreographerExecutor` to `CHOREOGRAPHER_EXECUTORS` (both default `["LocalCloudManager"]`), and its `sysMonitor` to SysMonitor; an executor also needs grants for the services its steps use. No executor is deployed by default. Host port: `CHOREOGRAPHER_PORT` (8457).

### Gatekeeper 4.6 compatibility

The `gatekeeper` microsystem preserves the v4.6 resource paths used by existing
GSD/ICN clients (`/gatekeeper/init_gsd`, `/gatekeeper/init_multi_gsd`, and
`/gatekeeper/init_icn`) while adopting the Arrowhead 5.2.2 system and
service-operation model. It has an independent SQLite store for neighbor clouds
and relays, registers `globalServiceDiscovery`, `interCloudNegotiation`,
`gatekeeperManagement`, and `monitor` as `generic_https`/`CERT_AUTH` services,
and binds every identity token to the caller's X.509 common name. Management is
restricted to `LocalCloudManager`; orchestration operations are restricted to
the registered orchestration systems and their ConsumerAuthorization policies.

Arrowhead 5.2.2 defines no official Gatekeeper wire protocol. Here the Gatekeepers of the local clouds exchange GSD and
ICN messages over the inter-cloud relay (`../Arrowhead-relay`, see "Inter-cloud exchange" below). A provider cloud
answers only with providers that its ConsumerAuthorization grants to the requesting consumer of the requesting cloud.

### GateTunnel (Gateway 4.6 successor)

The v5.2.2 replacement for the v4.6 `Gateway` is named `GateTunnel`. It retains
compatibility aliases for `/gateway/connect_provider`,
`/gateway/connect_consumer`, `/gateway/close_sessions`, and
`/gateway/publickey`, while its native v5 base path is `/gatetunnel`. GateTunnel
uses an independent persistent session store and publishes
`gateTunnelConnection`, `gateTunnelKey`, `gateTunnelManagement`, and `monitor`
as `generic_https`/`CERT_AUTH` services. Every control request requires both a
trusted client certificate and a matching Arrowhead identity token, with
ConsumerAuthorization policies limiting connection control to Gatekeeper and
the orchestration systems and management to LocalCloudManager.

For inter-cloud sessions negotiated by the Gatekeepers, GateTunnel is the data plane. On the consumer side it opens an
HTTPS listener (ports 8200–8299) that accepts only that session's consumer, with certificate plus bound token. It
forwards each request over the relay to the provider cloud's GateTunnel. That GateTunnel accepts only the negotiated
peer and paths below the provider's base path, and calls the provider with its own certificate and token
(`X-Arrowhead-Remote-Consumer` records the original consumer).

## Inter-cloud exchange

This cloud is the local cloud `TestCloud` (organization `Company`); its neighbour is `GoCloud`. System certificates are
`<System>.TestCloud.Company.arrowhead.eu`, issued by the self-signed cloud CA `TestCloud.Company.arrowhead.eu`. The two clouds
exchange services through the inter-cloud relay in `../Arrowhead-relay`: an MQTT broker over mutual TLS, trusted
through an organization CA that cross-signs both cloud CAs. Inside the cloud only the own cloud CA is trusted, so
certificates of the other cloud are refused everywhere except at the relay.

- **Example:** RandomDataProducer (`INTERCLOUD_ENABLED=true`) publishes every 30 seconds both to the local DataManager
  and, orchestrated with `ONLY_INTERCLOUD`, to the DataManager of `GoCloud`. There its values are stored as
  `RandomDataProducer/randomNumberProducerFromTestCloud` with SenML base name `urn:arrowhead:TestCloud:random-data-producer:`.
  `GET /random-data-producer/latest` shows the `interCloud` state.
- **Orchestration:** DynamicServiceOrchestration has `ENABLE_INTERCLOUD=true`. `ONLY_INTERCLOUD` goes straight to the
  Gatekeeper; `ALLOW_INTERCLOUD` falls back to it when no local provider is found.
- **Authorization:** `scripts/configure-intercloud.sh` (run at the end of `make up`, also `make intercloud`):
  - registers `GoCloud` as a Gatekeeper neighbour cloud;
  - grants `dataHistorian` at the local DataManager to `GoCloud`'s RandomDataProducer (cloud `GoCloud|Company`);
  - gives the Gatekeeper `authorizationManagement.check-policies` only. It needs that operation to check consumers
    of other clouds, because `authorization.verify` answers only the provider or consumer itself.

  The local GateTunnel holds the `dataHistorian` `put-data` grant (`configure-datamanager-policies.sh`), because it is
  the caller at DataManager on behalf of the remote consumer.
- **End-to-end protection (AH-GT-1, security finding J5):** Gatekeeper and GateTunnel run `FEDERATION_PROFILE=ah-gt-1`
  in both clouds. Per session, the two GateTunnels exchange signed ephemeral X25519 keys, signed with their relay keys
  and verified against the organization CA. Every relayed request and reply is then AES-256-GCM sealed, with sequence
  numbers against replay. The relay sees only ciphertext. Both clouds must use the same profile; there is no fallback
  to `legacy-mtls`.
- **Start order:** both clouds, then `make -C ../Arrowhead-relay up`.

## Operations

```sh
make status       # container state
make logs         # follow logs for default and profiled services
make smoke        # check the three mandatory core monitor endpoints
make smoke-onboarding # check ServiceRegistry and the focused Onboarding deployment
make smoke-onboarding-procedure # run the onboarding procedure end to end with the demo device
make smoke-all    # also check support and enabled optional systems
make smoke-security # console login, no default credentials, revocation at both brokers and the relay
make secrets      # add missing per-cloud secrets to .env
make rotate-secrets # new random secrets, applied to the running cloud, recreated in bootstrap order
make console-password # print the operator console password
make configure-orchestration-security-policies # restore the least-privilege DSO bootstrap grant
make up-monitor   # build/deploy the management API and graphical UI
make up-orchestration-manager # deploy Simple Store and the orchestration rule editor
make up-datamanager # build the Java DataManager jar, grant its policies, deploy it and refresh the monitor
make up-random-producer # generate X.509 material and deploy the 30-second producer
make up-sysmonitor # build/deploy SysMonitor, the AMQP and MQTT brokers, and the secured telemetry path
make amqp-acl      # regenerate amqp/definitions.json from amqp/acl and load it into the AMQP broker
make up-onboarding # build/deploy Onboarding and its database
make up-timemanager # issue certificate and identity, deploy TimeManager and its database, grant its policies
make up-eventhandler # issue certificate and identity, deploy EventHandler and its database, grant its policies
make up-configuration # issue certificate and identity, deploy Configuration and its database, grant its policies
make up-choreographer # issue certificate and identity, deploy Choreographer and its database, grant its policies
make jars         # rebuild the patched Java system jars (native sysMonitor)
make down         # stop/remove containers; preserve DB volumes and config
make clean        # also delete all local-cloud database volumes
```

The cloud survives restarts of containers and of Docker itself without manual steps. ServiceRegistry registers its own services as `generic_https`/`CERT_AUTH` at every start-up, and a Java system whose start-up fails because a dependency is not ready yet exits instead of hanging, so its restart policy retries until the dependency is available. `make up` remains the way to deploy changes. Configuration is bind-mounted from `runtime/` and survives `make down`. Database state is held in named Docker volumes. `make clean` is destructive and resets every database, but leaves generated configuration files in `runtime/`.

For access from another machine, set `BIND_ADDRESS=0.0.0.0` (or a specific host address). The systems advertise their Compose DNS names to one another; external clients should use the published host address and ports. Expose them only on a trusted test network and review the generated security configuration first.

## Version scope

The Compose model follows the official Arrowhead v5 aggregated deployment layout and image names. Version 5.2.2 is used because it is the latest 5.2 service release and contains security fixes. To reproduce 5.2.0 exactly, set `AH_VERSION=5.2.0` in `.env`.

Official references:

- [Arrowhead 5 Docker deployment documentation](https://aitia-iiot.github.io/ah5-docs-java-spring/home/getting_started/docker/docker_aggregated/)
- [Arrowhead 5.2.2 release](https://projects.eclipse.org/projects/iot.arrowhead/releases/5.2.2)
- [Arrowhead 5 Java/Spring core source](https://github.com/eclipse-arrowhead/ah5-core-java-spring/tree/v5.2.2)
