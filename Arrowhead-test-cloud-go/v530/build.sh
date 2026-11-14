#!/bin/sh
# SPDX-License-Identifier: EPL-2.0
# Go test cloud v5.3.0 (2026-11-11): every core and support system image from the primary source Eclipse-Arrowhead-go,
# with each folder's own Dockerfile and nothing else as build context. Native platform of this host (as the Java v5.3.0
# build); the 5.2 GoCloud's linux/amd64 pin belonged to the released upstream images.
# Each image gets the deployment helpers of this cloud in one layer on top (v530/health/Dockerfile):
#   ah-probe              TCP health probe (the systems are scratch images with mutual TLS on every request)
#   ah-lcm-launcher       LocalCloudManager only: secrets from files and the Docker socket via docker-proxy (v530/console)
# Tags: arrowhead-go-v530/<image>:20261114-v540 (the primary image itself: ...-base).
#   build.sh [IMAGE ...]     default: all; results in v530/build-results.tsv, logs in v530/build-logs/
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC=$(CDPATH= cd -- "$HERE/../../../Eclipse-Arrowhead-go" && pwd)
GO_IMAGE=golang:1.27.4-alpine@sha256:0a5f7fe796599ff487605987432e7619ae45beeb2fba4c2ce0b907879932aebf
TAG=20261114-v540
R=arrowhead-go-v530
# image name -> primary folder (ah5-LocalCloudConfigurator-go is a ColonyOS stack with a host executor, not built here)
MAP="ah5-aigym-go:ah5-AIGym-go ah5-blacklist-go:ah5-Blacklist-go ah5-certificateauthority-go:ah5-CertificateAuthority-go
ah5-choreographer-go:ah5-Choreographer-go ah5-configuration-go:ah5-Configuration-go ah5-datamanager-go:ah5-DataManager-go
ah5-deviceqosevaluator-go:ah5-DeviceQoSEvaluator-go ah5-eventhandler-go:ah5-EventHandler-go ah5-gatekeeper-go:ah5-Gatekeeper-go
ah5-gatetunnel-go:ah5-GateTunnel-go ah5-onboarding-go:ah5-Onboarding-go ah5-plantdescriptionengine-go:ah5-PlantDescriptionEngine-go
ah5-sysmonitor-go:ah5-SysMonitor-go ah5-timemanager-go:ah5-TimeManager-go ah5-translationmanager-go:ah5-TranslationManager-go
ah5-testtranslation-go:ah5-TestTranslation-go ah5-localcloudmanager-go:ah5-LocalCloudManager-go
authentication:ah5-core-go/authentication consumer-authorization:ah5-core-go/consumer-authorization
serviceorchestration-dynamic:ah5-core-go/serviceorchestration-dynamic
serviceorchestration-simple:ah5-core-go/serviceorchestration-simple serviceregistry:ah5-core-go/serviceregistry"
ARCH=$(docker version --format '{{.Server.Arch}}')
mkdir -p "$HERE/build-logs" "$HERE/health/bin" "$HERE/health/empty"
# helpers, with the same Go as the systems
for helper in probe:ah-probe console/launcher:ah-lcm-launcher; do
  dir=${helper%%:*}; out=${helper#*:}
  src=$HERE/health/$dir; [ -d "$src" ] || src=$HERE/$dir
  docker run --rm -v "$src":/src:ro -v "$HERE/health/bin":/out -w /src -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH="$ARCH" \
    -e GOFLAGS=-mod=mod -e GOCACHE=/tmp/cache -e GOMODCACHE=/tmp/mod "$GO_IMAGE" go build -trimpath -o "/out/$out" . \
    > "$HERE/build-logs/helper-$out.log" 2>&1
done
commit=$(git -C "$SRC" rev-parse HEAD)
dirty=$(git -C "$SRC" status --porcelain -- . | wc -l | tr -d ' ')
[ -f "$HERE/build-results.tsv" ] || printf 'image\tprimary folder\tcommit\tresult\tseconds\n' > "$HERE/build-results.tsv"
for pair in $MAP; do
  img=${pair%%:*}; dir=${pair#*:}
  [ $# -gt 0 ] && ! echo " $* " | grep -q " $img " && continue
  ref=$R/$img:$TAG
  start=$(date +%s)
  if docker build --progress=plain --build-arg GO_IMAGE=$GO_IMAGE --label "eu.arrowhead.primary-source=$SRC/$dir" \
       --label "eu.arrowhead.primary-commit=$commit" -t "$ref-base" "$SRC/$dir" > "$HERE/build-logs/$img.log" 2>&1 \
     && docker build --build-arg BASE="$ref-base" -t "$ref" "$HERE/health" >> "$HERE/build-logs/$img.log" 2>&1; then
    result=PASS
  else
    result=FAIL
  fi
  printf '%s\t%s\t%s%s\t%s\t%s\n' "$ref" "$dir" "$commit" "$([ "$dirty" = 0 ] || echo "+$dirty-uncommitted")" "$result" \
    "$(( $(date +%s) - start ))" >> "$HERE/build-results.tsv"
  echo "$result $ref"
done
