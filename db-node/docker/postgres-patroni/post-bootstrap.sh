#!/usr/bin/env bash
set -euo pipefail

psql -v ON_ERROR_STOP=1 -h /var/run/postgresql -U postgres -d postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'appuser') THEN
    CREATE ROLE appuser LOGIN PASSWORD '${APP_USER_PASSWORD}' CREATEDB;
  ELSE
    ALTER ROLE appuser LOGIN PASSWORD '${APP_USER_PASSWORD}' CREATEDB;
  END IF;
END
\$\$;

GRANT CREATE ON SCHEMA public TO appuser;
SQL

if ! psql -h /var/run/postgresql -U postgres -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = 'appdb'" | grep -q 1; then
  psql -v ON_ERROR_STOP=1 -h /var/run/postgresql -U postgres -d postgres -c "CREATE DATABASE appdb OWNER appuser"
fi
