#!/bin/sh
# Builds, offline with the local Maven image and ~/.m2, the Arrowhead 5.2.2 Java jars used by this cloud:
# the common library (native sysMonitor publisher), the core systems, DataManager, Blacklist,
# TranslationManager, DeviceQoSEvaluator, EventHandler and Onboarding. The released images are patched with these jars.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WS=$(CDPATH= cd -- "$ROOT_DIR/.." && pwd)

build() {
  project=$1
  shift
  echo "Building $project ..."
  # Without "clean" (not available offline) Maven would keep a jar whose own sources did not change,
  # still embedding the previous common library; remove the packaged jars so they are rebuilt.
  find "$WS/$project" -path '*/target/arrowhead-*-5.2.2.jar*' -type f -delete
  # Remove the compiled classes too: javac inlines library constants (e.g. Constants.AH_FRAMEWORK_VERSION)
  # into the classes that use them, so unchanged sources must be recompiled against the new library.
  find "$WS/$project" -type d -path '*/target/classes' -prune -exec rm -rf {} +
  docker run --rm -v "$WS/$project":/src -v "$HOME/.m2":/root/.m2 -w /src maven:3.9.9-eclipse-temurin-21 \
    mvn -q -o -Dcheckstyle.skip "$@"
}

build ah5-common-java-spring -DskipTests install
# DeviceDiscoveryServiceTest#testRegisterDeviceDifferentAddresses expects Windows line endings and fails on Linux.
build ah5-core-java-spring -pl serviceregistry,authentication,consumer-authorization,serviceorchestration-dynamic,serviceorchestration-simple -am \
  '-Dtest=!DeviceDiscoveryServiceTest#testRegisterDeviceDifferentAddresses' -Dsurefire.failIfNoSpecifiedTests=false package
build ah5-support-java-spring/Blacklist package
build ah5-support-java-spring/TranslationManager package
build ah5-support-java-spring/DeviceQoSEvaluator package
build ah5-support-java-spring/DataManager package
build ah5-support-java-spring/TimeManager package
build ah5-support-java-spring/EventHandler package
build ah5-support-java-spring/PlantDescriptionEngine package
build ah5-support-java-spring/Configuration package
build ah5-support-java-spring/Choreography package
build ah5-support-java-spring/Onboarding package
# Both test clouds run the same Onboarding jar.
for cloud in Arrowhead-test-cloud-java Arrowhead-test-cloud-go; do
  [ -d "$WS/$cloud/onboarding" ] && cp "$WS/ah5-support-java-spring/Onboarding/target/arrowhead-onboarding-5.2.2.jar" "$WS/$cloud/onboarding/app.jar"
done
echo "Java jars built"
