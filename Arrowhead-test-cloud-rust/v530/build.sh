#!/bin/sh
# SPDX-License-Identifier: EPL-2.0
# Rust test cloud v5.3.0 (2026-11-12): the one application image, built from the primary source Eclipse-Arrowhead-rust
# with v530/Dockerfile (context: the primary tree; v530/Dockerfile.dockerignore keeps target/ and .git out).
#   build.sh            -> arrowhead-rust-v530/rust-systems:20261112-v530, log v530/build-logs/rust-systems.log,
#                          result line in v530/build-results.tsv
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC=$(CDPATH= cd -- "$HERE/../../../Eclipse-Arrowhead-rust" && pwd)
REF=arrowhead-rust-v530/rust-systems:20261112-v530
mkdir -p "$HERE/build-logs"
commit=$(git -C "$SRC" rev-parse HEAD)
dirty=$(git -C "$SRC" status --porcelain | wc -l | tr -d ' ')
[ -f "$HERE/build-results.tsv" ] || printf 'image\tcommit\tresult\tseconds\n' > "$HERE/build-results.tsv"
start=$(date +%s)
if docker build --progress=plain -f "$HERE/Dockerfile" --label "eu.arrowhead.primary-source=$SRC" \
     --label "eu.arrowhead.primary-commit=$commit" -t "$REF" "$SRC" > "$HERE/build-logs/rust-systems.log" 2>&1; then
  result=PASS
else
  result=FAIL
fi
printf '%s\t%s%s\t%s\t%s\n' "$REF" "$commit" "$([ "$dirty" = 0 ] || echo "+$dirty-uncommitted")" "$result" \
  "$(( $(date +%s) - start ))" >> "$HERE/build-results.tsv"
echo "$result $REF"
[ "$result" = PASS ]
