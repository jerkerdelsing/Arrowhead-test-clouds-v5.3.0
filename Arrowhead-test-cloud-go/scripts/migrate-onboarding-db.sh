#!/bin/sh
# Brings an existing Onboarding database to the current schema (idempotent; new databases get it from
# onboarding/create_tables.sql at initialization): the enrollment tables, and the certificate columns added later.
set -eu
cd "$(dirname "$0")/.."
mysql() { docker compose exec -T onboarding-db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" ah_onboarding "$@" 2>/dev/null' sh "$@"; }
mysql < onboarding/create_tables.sql
for column in "onboarding_certificate_id bigint DEFAULT NULL" "onboarding_certificate_serial varchar(64) DEFAULT NULL" \
    "device_certificate_serial varchar(64) DEFAULT NULL"; do
  name=${column%% *}
  exists=$(printf "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='ah_onboarding' AND table_name='device_enrollment' AND column_name='%s';" "$name" | mysql -N)
  [ "$exists" = 1 ] || printf 'ALTER TABLE device_enrollment ADD COLUMN %s;\n' "$column" | mysql
done
echo "Onboarding database schema is current"
