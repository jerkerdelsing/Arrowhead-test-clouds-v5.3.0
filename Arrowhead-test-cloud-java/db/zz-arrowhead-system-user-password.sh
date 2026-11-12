#!/bin/bash
# Database initialization hook (docker-entrypoint-initdb.d, first start of an empty volume only), security findings H2/J1.
# The upstream Arrowhead database images create the system's own user (init.sql) with the published default password;
# replace it with this cloud's secret. Running clouds are changed by scripts/rotate-secrets.sh apply instead.
# With AH_DB_NAME set (support-system databases), the user is created if the schema scripts did not create it, and it
# gets data access (SELECT, INSERT, UPDATE, DELETE) on its own schema only: the systems validate, never change, the schema.
# Works both sourced and executed: Docker Desktop bind mounts pass the entrypoint's -x test even for mode 644 files,
# so the entrypoint may execute this file, and then docker_process_sql is not defined (2026-10-17).
# Passwords may come as files (Compose secrets, J7): AH_DB_USER_PASSWORD_FILE, MYSQL_ROOT_PASSWORD_FILE.
if [ -z "${AH_DB_USER_PASSWORD:-}" ] && [ -n "${AH_DB_USER_PASSWORD_FILE:-}" ]; then
  AH_DB_USER_PASSWORD=$(cat "$AH_DB_USER_PASSWORD_FILE")
fi
if [ -z "${MYSQL_ROOT_PASSWORD:-}" ] && [ -n "${MYSQL_ROOT_PASSWORD_FILE:-}" ]; then
  MYSQL_ROOT_PASSWORD=$(cat "$MYSQL_ROOT_PASSWORD_FILE")
fi
if [ -n "${AH_DB_USER:-}" ] && [ -n "${AH_DB_USER_PASSWORD:-}" ]; then
  if ! declare -F docker_process_sql >/dev/null; then
    docker_process_sql() {
      MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-}" mysql --protocol=socket -uroot -hlocalhost --comments "$@"
    }
  fi
  if [ -n "${AH_DB_NAME:-}" ]; then
    docker_process_sql --database=mysql <<-EOSQL || exit 1
	CREATE USER IF NOT EXISTS '${AH_DB_USER}'@'%' IDENTIFIED BY '${AH_DB_USER_PASSWORD}';
	REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${AH_DB_USER}'@'%';
	GRANT SELECT, INSERT, UPDATE, DELETE ON \`${AH_DB_NAME}\`.* TO '${AH_DB_USER}'@'%';
	DROP USER IF EXISTS '${AH_DB_USER}'@'localhost';
EOSQL
  fi
  docker_process_sql --database=mysql <<-EOSQL || exit 1
	ALTER USER IF EXISTS '${AH_DB_USER}'@'%' IDENTIFIED BY '${AH_DB_USER_PASSWORD}';
	ALTER USER IF EXISTS '${AH_DB_USER}'@'localhost' IDENTIFIED BY '${AH_DB_USER_PASSWORD}';
	FLUSH PRIVILEGES;
EOSQL
  echo "Arrowhead: password of database user ${AH_DB_USER} set from the cloud secrets"
fi
