#!/usr/bin/env bash
set -euo pipefail

render_configs() {
  mkdir -p /etc/patroni /etc/pgbackrest /etc/pgbouncer /var/lib/postgresql/data /var/lib/pgbackrest/spool /var/run/postgresql

  envsubst < /templates/patroni.yml > /etc/patroni/patroni.yml
  envsubst < /templates/pgbackrest.conf > /etc/pgbackrest/pgbackrest.conf
  envsubst < /templates/pgbouncer.ini > /etc/pgbouncer/pgbouncer.ini

  {
    printf '"%s" "md5%s"\n' "appuser" "$(printf '%s' "${APP_USER_PASSWORD}appuser" | md5sum | awk '{print $1}')"
    printf '"%s" "md5%s"\n' "postgres" "$(printf '%s' "${POSTGRES_SUPERUSER_PASSWORD}postgres" | md5sum | awk '{print $1}')"
  } > /etc/pgbouncer/userlist.txt

  chmod 600 /etc/pgbackrest/pgbackrest.conf /etc/pgbouncer/userlist.txt
}

start_pgbouncer() {
  pgbouncer /etc/pgbouncer/pgbouncer.ini &
}

bootstrap_pgbackrest() {
  (
    until curl -fs http://127.0.0.1:8008/primary >/dev/null 2>&1; do
      sleep 5
    done

    until pgbackrest --stanza="${BACKREST_STANZA}" stanza-create >/dev/null 2>&1; do
      sleep 5
    done
  ) &
}

render_configs
start_pgbouncer
bootstrap_pgbackrest

exec patroni /etc/patroni/patroni.yml
