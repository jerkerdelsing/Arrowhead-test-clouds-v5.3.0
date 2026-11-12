# Core database image from the primary source: Eclipse-Arrowhead-java/ah5-core-java-spring/<module>/src/main/resources/
# database on MySQL 8.4 LTS. Build context: ah5-core-java-spring. Replaces the earlier AITIA-derived images, whose
# init.sql grants to an 'ah-operator' user that is not created here and therefore fails on an empty volume
# (MySQL 8.4: ERROR 1410, found in the fresh rebuild of 2026-11-09). The test cloud's own init hooks (system user
# password from the cloud secret, AMQP interface templates, DSO plant rules) stay mounted by compose.yaml.
# SOS-16 (2026-11-10): MySQL 8.4.13, gosu rebuilt with a current Go, MySQL Shell removed (unused; it bundles Python
# packages with known vulnerabilities), Oracle Linux packages updated; the same as the primary deployment/database images.
FROM golang:1.27.4-alpine@sha256:0a5f7fe796599ff487605987432e7619ae45beeb2fba4c2ce0b907879932aebf AS gosu
RUN --mount=type=cache,target=/go/pkg/mod CGO_ENABLED=0 GOBIN=/out go install -trimpath -ldflags=-s github.com/tianon/gosu@v0.0.0-20261025094355-29b939aa5bd4
FROM mysql:8.4.13@sha256:a81d043930e51745522bd5c430961cf8286f0a23f0a9a2a6e0108f7ea71b0902
COPY --from=gosu /out/gosu /usr/local/bin/gosu
RUN microdnf -y remove mysql-shell && microdnf -y update && microdnf clean all && gosu nobody true
ARG MODULE
COPY ${MODULE}/src/main/resources/database/ /db-scripts/
RUN mv /db-scripts/create_empty_db.sql /docker-entrypoint-initdb.d/init.sql \
 && sed -i -E 's/^(source[[:space:]]+)([^[:space:]]+)/\1..\/db-scripts\/\2/' /docker-entrypoint-initdb.d/init.sql \
 && chmod -R a+rX /db-scripts /docker-entrypoint-initdb.d
WORKDIR /db-scripts
