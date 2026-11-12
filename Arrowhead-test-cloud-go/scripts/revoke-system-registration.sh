#!/bin/sh
# Removes a system and its service instances from the ServiceRegistry (management, as Sysop), so that another
# implementation of the system can register (2026-10-24, swap-* / restore-* targets): the registry refuses a
# registration whose metadata (e.g. "implementation") differs from the registered system's, as the Java reference.
# Usage: revoke-system-registration.sh <SystemName>
set -eu
cd "$(dirname "$0")/.."
. scripts/lib-secrets.sh
. scripts/registry-auth.sh
name=$1
case "$name" in *[!A-Za-z0-9_]*|'') echo "invalid system name" >&2; exit 1 ;; esac
sysop_login || { echo "Sysop login failed" >&2; exit 1; }
code=$(curl -sS -o /dev/null -w '%{http_code}' $SYSOP_TLS -H "$SYSOP_AUTH" -X DELETE "https://127.0.0.1:7443/serviceregistry/mgmt/systems?names=$name")
case "$code" in 200|204) echo "Registration of $name removed" ;; *) echo "Removing the registration of $name answered $code" >&2; exit 1 ;; esac
