#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

wait_for_cluster

write_via_global_host() {
  local node="$1"
  local note="$2"
  local timeout="${3:-30}"
  local deadline=$((SECONDS + timeout))
  local output=""

  while (( SECONDS < deadline )); do
    if output="$(compose_exec "${node}" bash -lc "export PGPASSWORD='${POSTGRES_SUPERUSER_PASSWORD}'; export PGCONNECT_TIMEOUT=5; cat <<'SQL' | timeout 10 psql 'host=${DB_WRITE_HOST} port=5000 user=postgres dbname=postgres connect_timeout=5' -v ON_ERROR_STOP=1
INSERT INTO failover_demo(note) VALUES ('${note}');
SQL" 2>&1)"; then
      [[ -n "${output}" ]] && printf '%s\n' "${output}"
      return 0
    fi
    sleep 3
  done

  [[ -n "${output}" ]] && printf '%s\n' "${output}" >&2
  return 1
}

old_primary="$(detect_primary)"

if [[ "${old_primary}" == "city-a" ]]; then
  new_primary="city-b"
else
  new_primary="city-a"
fi

echo "Current primary: ${old_primary}"
echo "Expected promotion target: ${new_primary}"

echo
echo "Creating a test table and writing through the global write VIP..."
compose_exec "${old_primary}" bash -lc "export PGPASSWORD='${POSTGRES_SUPERUSER_PASSWORD}'; cat <<'SQL' | psql 'host=${DB_WRITE_HOST} port=5000 user=postgres dbname=postgres connect_timeout=5' -v ON_ERROR_STOP=1
CREATE TABLE IF NOT EXISTS failover_demo (
    id bigserial PRIMARY KEY,
    note text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO failover_demo(note) VALUES ('before-failover');
SQL"

echo
echo "Killing ${old_primary} with SIGKILL..."
compose_kill_node SIGKILL "${old_primary}"

echo "Waiting for promotion on ${new_primary}..."
wait_for_role "${new_primary}" primary 180

echo "Promotion complete. Verifying relaxed synchronous mode keeps writes available without the second city..."
if write_via_global_host "${new_primary}" "write-available-without-sync-standby" 45; then
  echo "Expected in relaxed mode: write path remained available."
else
  echo "Warning: write path still failed while the second city was absent."
fi

echo
echo "Starting ${old_primary} again..."
compose_start_node "${old_primary}"

echo "Waiting for ${old_primary} to rejoin as replica..."
wait_for_role "${old_primary}" replica 240

echo
echo "Checking Patroni logs for pg_rewind activity..."
if compose_logs "${old_primary}" --tail 500 | grep -qi "pg_rewind"; then
  echo "pg_rewind detected in ${old_primary} logs."
else
  echo "Warning: pg_rewind was not found in the recent log tail. Patroni may have rejoined using timeline recovery."
fi

echo
echo "Writing again after the replica returns..."
write_via_global_host "${new_primary}" "after-rejoin" 45

echo
echo "Final row count on ${new_primary}:"
compose_exec "${new_primary}" bash -lc "export PGPASSWORD='${POSTGRES_SUPERUSER_PASSWORD}'; psql 'host=127.0.0.1 port=5432 user=postgres dbname=postgres connect_timeout=5' -Atc 'SELECT count(*) FROM failover_demo;'"
