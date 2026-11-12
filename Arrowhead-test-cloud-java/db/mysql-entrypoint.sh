#!/bin/bash
# Entrypoint of every database container (security finding J7). The passwords come as files (Compose secrets,
# MYSQL_ROOT_PASSWORD_FILE and AH_DB_USER_PASSWORD_FILE); the official entrypoint reads them into variables for the
# initialization, and would then exec mysqld with them in its environment. This wrapper runs the official entrypoint
# unchanged, except that the final exec drops the secrets first, so mysqld's /proc/1/environ holds none.
set -eo pipefail
source /usr/local/bin/docker-entrypoint.sh
exec() {
  unset MYSQL_ROOT_PASSWORD MYSQL_PASSWORD AH_DB_USER_PASSWORD MYSQL_PWD
  builtin exec "$@"
}
_main "$@"
