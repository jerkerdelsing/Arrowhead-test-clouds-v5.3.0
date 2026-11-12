#!/bin/sh
set -eu
test -s /run/trust/current.crl.pem
cp /run/trust/current.crl.pem /tmp/arrowhead-crl.pem
broker=$$
(
  last=$(cksum /run/trust/current.crl.pem)
  while sleep 2; do
    if [ ! -s /run/trust/current.crl.pem ]; then kill -TERM "$broker"; exit 1; fi
    current=$(cksum /run/trust/current.crl.pem)
    if [ "$current" != "$last" ]; then
      cp /run/trust/current.crl.pem /tmp/crl.pending
      mv /tmp/crl.pending /tmp/arrowhead-crl.pem
      kill -HUP "$broker" || exit 0
      last=$current
    fi
  done
) &
exec /usr/sbin/mosquitto -c /mosquitto/config/mosquitto.conf
