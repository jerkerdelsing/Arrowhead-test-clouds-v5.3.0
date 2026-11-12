#!/bin/sh
# Mosquitto entrypoint with certificate revocation (security finding H3).
# Concatenates the CRLs named by CRL_SOURCES (space-separated paths, globs allowed) into CRL_FILE, which
# mosquitto.conf names as crlfile, then starts Mosquitto. A watcher compares the sources every CRL_POLL_SECONDS and,
# on a change, rebuilds CRL_FILE and sends SIGHUP: Mosquitto reloads the CRL without dropping connections.
# Fail closed: Mosquitto is not started without any CRL, and CRL_FILE is never emptied or removed (a missing file
# after a reload would disable the check). An expired CRL makes Mosquitto refuse every client.
set -eu
CRL_FILE=${CRL_FILE:-/tmp/arrowhead-crl.pem}
CRL_SOURCES=${CRL_SOURCES:-/crl/ca.crl}
CRL_POLL_SECONDS=${CRL_POLL_SECONDS:-10}

sources_digest() { for f in $CRL_SOURCES; do [ -f "$f" ] && cksum "$f"; done 2>/dev/null; true; }

combine() {
  tmp="$CRL_FILE.tmp"
  : > "$tmp"
  for f in $CRL_SOURCES; do [ -f "$f" ] && cat "$f" >> "$tmp"; done
  if grep -q "BEGIN X509 CRL" "$tmp"; then chmod 644 "$tmp"; mv "$tmp" "$CRL_FILE"; return 0; fi
  rm -f "$tmp"; return 1
}

until combine; do
  echo "crl-watch: no CRL found in $CRL_SOURCES; waiting" >&2
  sleep 5
done
echo "crl-watch: CRL loaded from $CRL_SOURCES"

broker=$$
(
  last=$(sources_digest)
  while sleep "$CRL_POLL_SECONDS"; do
    current=$(sources_digest)
    if [ "$current" != "$last" ] && combine; then
      last=$current
      echo "crl-watch: CRL changed; reloading the broker"
      kill -HUP "$broker" 2>/dev/null || exit 0
    fi
  done
) &

exec /docker-entrypoint.sh "$@"
