#!/bin/sh
# Cross-compiles the native Go core (../ah5-core-go) and support (../ah5-support-go) systems for the container platform
# into go-native-full/build/ (image arrowhead-go-native, Dockerfile.prebuilt), plus the ServiceRegistry binary for its
# own image (../ah5-core-go/ServiceRegistry/build). Static binaries (CGO disabled) for a scratch image.
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
WS=$(cd .. && pwd)
platform=$(sed -n 's/^DOCKER_PLATFORM=//p' .env 2>/dev/null | tail -n 1)
platform=${platform:-linux/amd64}
export CGO_ENABLED=0 GOOS=${platform%%/*} GOARCH=${platform#*/}
OUT="$ROOT/go-native-full/build"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "Building Go core systems ($GOOS/$GOARCH) ..."
for system in authentication consumer-authorization serviceorchestration-dynamic serviceorchestration-simple; do
  (cd "$WS/ah5-core-go" && go build -trimpath -o "$OUT/$system" "./$system")
done
(cd "$WS/ah5-core-go/ServiceRegistry" && go build -trimpath -o build/serviceregistry-linux-amd64 .)

echo "Building Go support systems ($GOOS/$GOARCH) ..."
for system in AIGym Blacklist CertificateAuthority Choreographer Configuration DataManager DeviceQoSEvaluator EventHandler \
    Gatekeeper GateTunnel Onboarding PlantDescriptionEngine SysMonitor TimeManager TranslationManager TestTranslation; do
  (cd "$WS/ah5-support-go" && go build -trimpath -ldflags "-X main.defaultSystem=$system" -o "$OUT/$system" ./cmd/support)
done
(cd "$ROOT/go-native-full/probe" && [ -f go.mod ] || go mod init arrowhead/go-native-probe >/dev/null 2>&1; cd "$ROOT/go-native-full/probe" && go build -trimpath -o "$OUT/ah-probe" .)

(cd "$OUT" && shasum -a 256 * > "$ROOT/go-native-full/SHA256SUMS")
echo "Go native binaries in go-native-full/build ($(ls "$OUT" | wc -l | tr -d ' ') files)"
