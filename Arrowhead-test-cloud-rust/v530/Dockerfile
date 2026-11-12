# SPDX-License-Identifier: EPL-2.0
# Rust test cloud v5.3.0 (2026-11-12): every Arrowhead program of this cloud built from the primary source
# Eclipse-Arrowhead-rust (build context, see build.sh), native platform of this host.
#   arrowhead-core       ServiceRegistry, Authentication, ConsumerAuthorization, both orchestrators
#   arrowhead-support    the 15 support systems
#   RandomDataProducer   test application (ah5-support-runtime-rust/src/bin)
#   LocalCloudManager, localcloudmanager-docker-proxy   console and its Docker gateway (ah5-LocalCloudManager-rust)
# Base images as ah5-core-rust/Dockerfile (SOS-16: Rust 1.99, Debian 13). Runtime: curl for health checks, OpenSSL.
FROM rust:1.99-trixie@sha256:8a4e90c7946b74626488b1446f712c0fe0ed1a596cbd3d871684bc9c5433ae07 AS build
WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked --bin arrowhead-core --bin arrowhead-support --bin RandomDataProducer \
      --bin LocalCloudManager --bin localcloudmanager-docker-proxy \
 && mkdir /out && cd /src/target/release \
 && cp arrowhead-core arrowhead-support RandomDataProducer LocalCloudManager localcloudmanager-docker-proxy /out/

FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2
RUN apt-get update && apt-get -y upgrade && apt-get install -y --no-install-recommends curl ca-certificates libssl3t64 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /usr/local/bin/
USER 501:20
ENTRYPOINT ["/usr/local/bin/arrowhead-core"]
