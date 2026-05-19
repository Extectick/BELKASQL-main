#!/usr/bin/env bash
set -euo pipefail

envsubst < /templates/haproxy.cfg > /usr/local/etc/haproxy/haproxy.cfg

sanitize_server_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_' | sed -E 's/^_+//; s/_+$//; s/^([0-9])/_\1/'
}

append_legacy_db_nodes() {
  if [[ -n "${DB_NODES:-}" ]]; then
    return 0
  fi

  local nodes=""
  [[ -n "${DB_HOST_A:-}" ]] && nodes="${nodes} city-a=${DB_HOST_A}"
  [[ -n "${DB_HOST_B:-}" ]] && nodes="${nodes} city-b=${DB_HOST_B}"
  [[ -n "${DB_HOST_C:-}" ]] && nodes="${nodes} city-c=${DB_HOST_C}"
  DB_NODES="${nodes# }"
}

render_db_servers() {
  append_legacy_db_nodes

  if [[ -z "${DB_NODES:-}" ]]; then
    echo "DB_NODES is empty. Set DB_NODES=\"city-a=10.77.0.2 city-b=10.77.0.3\"." >&2
    exit 1
  fi

  local seen=" "
  local item name host server_name
  # Accept spaces, commas and newlines as separators.
  for item in ${DB_NODES//,/ }; do
    [[ -n "${item}" ]] || continue
    if [[ "${item}" == *"="* ]]; then
      name="${item%%=*}"
      host="${item#*=}"
    else
      host="${item}"
      name="${item%%:*}"
    fi
    host="${host%/}"
    if [[ -z "${name}" || -z "${host}" ]]; then
      echo "Invalid DB_NODES item: ${item}" >&2
      exit 1
    fi

    server_name="$(sanitize_server_name "${name}")"
    if [[ "${seen}" == *" ${server_name} "* ]]; then
      echo "Duplicate DB server name after sanitizing: ${server_name}" >&2
      exit 1
    fi
    seen="${seen}${server_name} "
    printf '    server %s %s:6432 check port 8008\n' "${server_name}" "${host}"
  done
}

servers_file="$(mktemp)"
render_db_servers > "${servers_file}"
sed -i "/# __PATRONI_PRIMARY_SERVERS__/ { r ${servers_file}
  d
}" /usr/local/etc/haproxy/haproxy.cfg
sed -i "/# __PATRONI_REPLICA_SERVERS__/ { r ${servers_file}
  d
}" /usr/local/etc/haproxy/haproxy.cfg
rm -f "${servers_file}"

if [[ "${LB_RENDER_ONLY:-false}" == "true" ]]; then
  cat /usr/local/etc/haproxy/haproxy.cfg
  exit 0
fi

if [[ "${KEEPALIVED_ENABLED:-true}" == "true" ]]; then
  envsubst < /templates/keepalived.conf > /etc/keepalived/keepalived.conf

  cat > /etc/keepalived/check_haproxy.sh <<'EOF'
#!/usr/bin/env bash
pidof haproxy >/dev/null 2>&1
EOF

  chmod +x /etc/keepalived/check_haproxy.sh

  keepalived --dont-fork --log-console -f /etc/keepalived/keepalived.conf &
fi

exec haproxy -W -db -f /usr/local/etc/haproxy/haproxy.cfg
