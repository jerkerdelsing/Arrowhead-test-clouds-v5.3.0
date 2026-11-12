# GateTunnel 5.2.2

GateTunnel is the Arrowhead 5.2.2-compatible successor to the Arrowhead 4.6
Gateway microsystem. Its native API base path is `/gatetunnel`; compatibility
aliases remain under `/gateway` for the v4 connection-control operations.

## Security

- TLS 1.2 or TLS 1.3 with mandatory client certificates
- Arrowhead Authentication identity tokens
- X.509 common-name and token-identity binding
- ConsumerAuthorization policies for connection, key, and management services
- `generic_https` / `CERT_AUTH` ServiceRegistry interfaces

The expected system certificate common name is:

`GateTunnel.TestCloud.Company.arrowhead.eu`

## Registered services

- `gateTunnelConnection`
- `gateTunnelKey`
- `gateTunnelManagement`
- `monitor`

## Runtime configuration

See `compose.example.yaml`. The service requires the local-cloud CA, GateTunnel
certificate and private key mounted under `/certs`. Run the included identity
and policy scripts after Authentication and ConsumerAuthorization are ready.
Add `registry-bootstrap-proxy.conf` to the private ServiceRegistry bootstrap
proxy, or replace `SERVICE_REGISTRY_URL` with an equivalent authenticated v5
registry endpoint for the GateTunnel system identity.

The service implements the secured connection/session control lifecycle and
persistent port allocation. Cross-cloud payload forwarding requires a separately
deployed relay transport; no unauthenticated raw TCP bridge is exposed.
