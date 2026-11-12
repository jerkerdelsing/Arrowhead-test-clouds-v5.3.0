#!/bin/sh
# Credential bundle of a Rust support system (ah5-support-rust) swapped into GoCloud (2026-10-24):
#   security/bundles-rust/<service>/  ca.pem, cert.pem, key.pem, password (the system's identity password)
# Directory 700, files 600 (Docker Desktop lets the container's user read them). Idempotent.
# Usage: make-rust-bundle.sh <service> <certificate stem> <password key>, e.g. timemanager timemanager AH_PW_TMG
set -eu
cd "$(dirname "$0")/.."
. scripts/lib-secrets.sh
[ $# -eq 3 ] || { echo "usage: $0 <service> <certificate stem> <password key>" >&2; exit 1; }
X509=security/x509
OUT=security/bundles-rust/$1
umask 077
mkdir -p "$OUT"
chmod 700 security/bundles-rust "$OUT"
cp "$X509/ca.crt" "$OUT/ca.pem"
cp "$X509/$2.crt" "$OUT/cert.pem"
cp "$X509/$2.key" "$OUT/key.pem"
printf '%s\n' "$(secret "$3")" > "$OUT/password"
chmod 600 "$OUT"/*
echo "Rust $1 credential bundle in $OUT"
