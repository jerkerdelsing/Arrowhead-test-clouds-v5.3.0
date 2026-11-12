# Java support-system migration — 2026-10-16

Cloud: `/Users/jerkerdelsing/Work/lule/EISLAB/Project/Eclipse/Arrowhead/Arrowhead-test-cloud`.

## Implemented and deployed

CertificateAuthority, Gatekeeper, GateTunnel and SysMonitor have native Java 21
implementations in `../ah5-support-java-spring/JavaSupportRuntime`. The cloud's
Compose configuration selects `JAVA_SUPPORT_ROLE` in the shared image
`arrowhead-native-java-support:5.2.2-port-20261016`. None of these backends launches
Python. The original Python source and image identities are retained for rollback.
Go and Rust deployments were not changed.

The final process inventory at 03:08 UTC found all 21 tracked Java-cloud systems running:
20 Java backends and the existing Node.js LocalCloudManager backend. The separate
RandomDataProducer demonstration application remains Python; it is not one of the
four translated core/support systems. No claim of a Python-free Docker environment
or an all-Java LocalCloudManager is made.

## Verified behavior

- 14 JUnit tests passed: durable monitoring/outbox and control-session storage,
  subscription revision conflicts, SQL and negotiated method/path isolation,
  real mTLS/token-to-certificate binding, Authentication identity pinning before
  credential transmission, concurrent expired-token renewal without login storms,
  CSR issuance/profile restrictions, signed revocation
  lists and cross-signed-CA-compatible CRL authority identifiers.
- The shaded JAR's SQLite native library was loaded and exercised in the final
  Java JRE image, not only from Maven's test classpath.
- Monitoring history/API and management/provider/subscription requests succeeded.
  Four sampled pre-migration observations (one from each translated system) were
  returned with identical IDs and full stored payloads. History grew from 275,727
  backed-up observations to more than 285,000; retention remained 30 days, no
  observations were pruned during the recorded checks, and the output outbox
  drained to zero.
- Native observations from all four replacements have `implementation=java` and
  `publisherMode=native`. AMQP intake and MQTT5 output connected successfully.
- A temporary disabled `JavaPortProbe` subscription was created, updated with the
  correct revision, rejected with HTTP 409 for a stale revision, then deleted
  with HTTP 204. Existing subscriptions were not changed.
- Global service discovery from Go to Java returned one authorized provider and
  zero failed clouds. Both live producers resumed forwarding to the other
  cloud's DataManager. Final recorded counters were Java 760 and Go 822,
  both running without a last error. Direct Java-to-Go discovery and negotiation
  also succeeded. The existing Java dynamic orchestrator was restarted (without
  changing its image/configuration) after its logs showed no response from the
  working internal Gatekeeper endpoint. Automatic forwarding recovered afterward;
  stale client/DNS connection state is the inferred cause, not independently proven.
- The Java CA's generated CRL passed OpenSSL verification of the relay's existing
  cross-signed GateTunnel certificate. The cloud CA certificate fingerprint
  remained `2f721a9a70bc9487810ec0088e6f6bee81f548329a50ad19d3be36ca5435afd1`.
- Internal certificate-authenticated HTTPS requests to CertificateAuthority and
  Gatekeeper both returned HTTP 200 with `implementation=java`.
  Protected internal management requests confirmed all 49 issued certificates,
  zero trusted keys and one neighbour; requests without tokens were refused
  with HTTP 401.

This is targeted migration acceptance, not complete independent certification of
every Arrowhead 5.2.2 operation or protocol. Certificate issuance/revocation was
tested with an isolated PKI rather than creating production-cloud certificates.

## Host-port forwarding — resolved after approved Docker restart

Direct host connections to `https://127.0.0.1:8448` (CertificateAuthority) and
`https://127.0.0.1:8449` (Gatekeeper) failed with an EOF during TLS, while the same
services answered correctly over the cloud's Docker network. Docker retained the
configured host bindings but reported empty published-port entries. Removing
unrelated advertised ports, targeted service restarts and reconnecting the CA's
network attachment did not resolve this in the recorded checks.

Docker startup commands also stalled at Created; bounded exact-container-ID API
requests were used to start the selected services. These observations point to
Docker networking/startup behavior, not proof of a particular Docker bug.
Following explicit user approval, Docker Desktop was restarted on 2026-10-16.
The configured localhost port bindings returned, and all four Java replacement
HTTPS health endpoints returned HTTP 200. Protected CA certificate/key and
Gatekeeper neighbour-list requests also returned HTTP 200; missing tokens and
declared identities were refused with HTTP 401. All 49 CA records were retained.
All three cloud UIs returned HTTP 200 and the process inventory retained the
same 21 Java-cloud, 21 Go-cloud and nine Rust-cloud deployed systems. No volumes
were removed. Several existing Java clients failed authentication while the
services started together. Authentication was confirmed ready, then the existing
Java ServiceRegistry, ConsumerAuthorization and DynamicServiceOrchestration
containers were restarted in dependency order, without image/configuration or
database changes. No containers remained starting or unhealthy afterward.

Both producers resumed real inter-cloud forwarding without last errors (recorded
post-restart in-memory counters: Java 28, Go 27; these counters reset on process
restart). The authenticated Java monitoring view subsequently returned HTTP 200,
22 monitored systems and 307,877 stored observations. All four historical sample
IDs/payloads remained identical after the restart, and protected CA management
still returned 49 issued records. Post-restart checks are recorded separately in
the evidence files below. This closes the earlier CA/Gatekeeper host-port blocker.

The LocalCloudManager UI remains `http://127.0.0.1:8490/`; its internal monitoring
and inter-cloud views returned HTTP 200 in the final live checks. A concurrent
monitoring-view failure exposed a token-refresh race, fixed in the final build.
After deliberately replacing the collector's token, both concurrent dashboard
reads returned HTTP 200, 22 monitored systems, 285,133 stored observations and
zero per-system errors. The 14-test build also includes a deterministic concurrent
401/renewal regression test. Certificates and identity tokens remain
required for protected service APIs; the UI uses the existing console login.

## Preserved data and rollback

The four existing named data volumes, certificate bundles, service passwords,
ports and registrations were reused. Consistent pre-migration SQLite backups
contain 49 issued CA records, zero trusted keys, one configured neighbour, zero
legacy tunnel-control sessions, six monitoring audit entries and 275,727
monitoring observations. No private CA key was copied into the evidence directory.
The CA's existing root key remains mounted read-only only where signing requires
it; no CA or service certificate was rotated.

`compose.pre-java-support-20261016.yaml` retains the original Compose configuration.
The workspace evidence `images-before.txt` records exact old image IDs, including
the GateTunnel image whose tag no longer identified its running image. A rollback
must select those recorded images, recreate only the four affected services, and
retain the current live volumes. Do **not** restore an old database snapshot over
new monitoring or certificate records. Do not run `compose down -v`.

## Security limits

Federation explicitly uses the existing Go peer's `legacy-mtls` profile. Transport
connections are mutually authenticated, but the broker can inspect relay payloads;
AH-GT-1 end-to-end encryption is not implemented in this port. Requests requiring
that encrypted profile are refused rather than silently downgraded. The original
legacy tunnel-control API retains its stored-session semantics; it is not a new
AMQP tunnel data plane.

The containers use a read-only root filesystem, bounded memory/processes, and
drop capabilities except `DAC_OVERRIDE` to retain access to the existing volume
ownership. They are not rootless. `/tmp` is explicitly executable for SQLite JNI.
This language migration does not close unrelated cross-cloud private-key backup,
HTTP-client revocation-enforcement, or console-cookie isolation findings.

## Evidence

Workspace: `java-support-port/evidence/`.

- `database-before.json` and `before-*.sqlite`: consistent backup schemas/counts.
- `build.log`: 14 passing tests and the packaged-storage check for the final source.
- `tests.log`: an earlier independent rebuild/test record (13 tests, preceding
  the additional concurrent-token-renewal regression test).
- `history-final-ports.json`: exact historical-payload checks, Java-native latest
  observations, subscription revision checks and cleanup.
- `federation-final.json`: successful two-cloud discovery and actual forwarding.
- `language-final.json`: process inventory (20 Java + one Node.js).
- `api-final-ports.json`: APIs, security refusals and unresolved host TLS failures.
- `internal-final.json`: preserved CA/key/neighbour counts via protected internal
  mTLS endpoints.
- `concurrency-final.json`: successful concurrent dashboard reads after forced
  collector-token replacement.
- `discovery-java-to-go.json`: successful Java-to-Go discovery and live negotiation.
- `api-after-docker-restart.json`, `history-after-docker-restart.json`,
  `federation-after-docker-restart.json`, `language-after-docker-restart.json`:
  post-restart endpoint/security, data-preservation and recovery checks.

The original 2026-10-15 language coverage report is historical. The Go cloud still
has three native Go systems and mixed-language support; Rust still has nine
deployed systems and twelve missing support systems. Translation of these four
Java-cloud services does not change those findings.
