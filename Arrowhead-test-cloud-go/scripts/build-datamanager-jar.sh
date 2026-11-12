#!/bin/sh
# Builds the Java DataManager jar offline with the local Maven image and ~/.m2 repository.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC_DIR=$(CDPATH= cd -- "$ROOT_DIR/../ah5-support-java-spring/DataManager" && pwd)

docker run --rm -v "$SRC_DIR":/src -v "$HOME/.m2":/root/.m2 -w /src maven:3.9.9-eclipse-temurin-21 \
  mvn -q -o -DskipTests -Dcheckstyle.skip package
echo "DataManager jar built: $SRC_DIR/target/arrowhead-datamanager-5.2.2.jar"
