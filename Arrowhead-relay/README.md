# Arrowhead v5.3.0 relay

MQTT broker (Eclipse Mosquitto 2.0.22, mutual TLS) for the inter-cloud integration tests of the primary Java tree
(`Eclipse-Arrowhead-java`). It is the relay over which the Gatekeeper and GateTunnel relay clients exchange messages.
None of the v5.3.0 test clouds is federated (section 8, item 4 of the release notes defers that), so no cloud is
connected to it; it serves the tests in `Eclipse-Arrowhead-java/verification/tools/relay_integration_tests.py`.

| | |
|---|---|
| Compose project | `arrowhead-relay`, one service `relay` |
| Network | `arrowhead-relay-network`, alias `arrowhead-relay`, port 8883 |
| Host port | `127.0.0.1:8894` (8893 is left for an organisation relay of federated clouds) |
| Image | `eclipse-mosquitto:2.0.22`, pinned by digest |
| Hardening | user 1883, read-only root, `/tmp` tmpfs only, no capabilities, no-new-privileges, 128 MB, 64 processes, half a CPU |

## Use

```sh
make up       # scripts/generate-pki.sh (kept when present), then docker compose up -d --wait
make status
make down
```

Then, in `Eclipse-Arrowhead-java`:

```sh
python3 verification/tools/relay_integration_tests.py
```

It runs Gatekeeper `RelayRoundTripIT` and GateTunnel `RelayRoundTripTest` in the Maven build image on the relay's
network and writes `verification/release-5.3.0/relay-integration-tests.json`.

## Trust

`scripts/generate-pki.sh` writes a test PKI to `security/` (not in git; `--force` regenerates it):

| File | Purpose |
|---|---|
| `relay-ca.crt`, `relay-ca.crl` | test organisation CA `Relay test CA.Company.arrowhead.eu` and its CRL (90 days) |
| `relay.crt` | relay server certificate, DNS `arrowhead-relay` and `localhost`, IP `127.0.0.1` |
| `trust.pem` | what the relay accepts: `relay-ca.crt` and the organisation CA of the GateTunnel AH-GT-1 test fixtures |
| `clients/gatekeeper/` | `ca.crt` and the test identities `a` (`Gatekeeper.TestCloud…`) and `b` (`Gatekeeper.OtherCloud…`) |
| `clients/gatetunnel/` | the CA bundle and the relay CA's CRL that the GateTunnel relay client checks the relay against |

A client must present a certificate that chains to `trust.pem`; its CN is its MQTT user name. Clients without a
certificate and certificates of other CAs are refused (checked 2026-11-12).

**Not for federation as it stands.** The keys are test keys, and there is no ACL: every authenticated client may
publish and subscribe on every topic, which `RelayRoundTripIT` needs for its observer. A relay for federated clouds
needs the organisation PKI with name-constrained cross-certificates, the per-identity ACL and the organisation CRL
check of the earlier relay (`OLD/Arrowhead/Arrowhead-relay`).

## Results (2026-11-12, commit 02b4b4e2)

- Gatekeeper `RelayRoundTripIT`: 3 of 3 pass.
- GateTunnel `RelayRoundTripTest`: 1 of 1 passes.

The relay's log shows each test identity connecting under its own CN.
