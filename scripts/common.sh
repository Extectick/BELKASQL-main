#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_USER_PASSWORD="${APP_USER_PASSWORD:-app-pass}"
POSTGRES_SUPERUSER_PASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-postgres-pass}"
PGBACKREST_STANZA="${PGBACKREST_STANZA:-belka}"
PGBACKREST_BUCKET="${PGBACKREST_BUCKET:-belka-pgbackrest}"
MINIO_SECONDARY_ENDPOINT="${MINIO_SECONDARY_ENDPOINT:-minio-secondary:9000}"
MINIO_SECONDARY_ROOT_USER="${MINIO_SECONDARY_ROOT_USER:-miniosecondary}"
MINIO_SECONDARY_ROOT_PASSWORD="${MINIO_SECONDARY_ROOT_PASSWORD:-miniosecondary123}"
BELKA_NETWORK_NAME="${BELKA_NETWORK_NAME:-belkasql_belka-net}"
DB_WRITE_HOST="${DB_WRITE_HOST:-db-write.local}"
DB_READ_HOST="${DB_READ_HOST:-db-read.local}"

DB_TEMPLATE="${PROJECT_ROOT}/db-node/docker-compose.yml"
CONTROL_TEMPLATE="${PROJECT_ROOT}/control-node/docker-compose.yml"
LB_TEMPLATE="${PROJECT_ROOT}/lb-node/docker-compose.yml"
STORAGE_TEMPLATE="${PROJECT_ROOT}/storage-node/docker-compose.yml"
OBSERVABILITY_TEMPLATE="${PROJECT_ROOT}/observability-node/docker-compose.yml"

host_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

docker_cmd() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker "$@"
}

docker_compose_cmd() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker compose "$@"
}

ensure_network() {
  if ! docker_cmd network inspect "${BELKA_NETWORK_NAME}" >/dev/null 2>&1; then
    docker_cmd network create --driver bridge --subnet 172.28.0.0/16 "${BELKA_NETWORK_NAME}" >/dev/null
  fi
}

compose_node() {
  local node="$1"
  shift

  case "${node}" in
    city-a)
      docker_compose_cmd --env-file "$(host_path "${PROJECT_ROOT}/db-node/env/city-a.env")" -f "$(host_path "${DB_TEMPLATE}")" "$@"
      ;;
    city-b)
      docker_compose_cmd --env-file "$(host_path "${PROJECT_ROOT}/db-node/env/city-b.env")" -f "$(host_path "${DB_TEMPLATE}")" "$@"
      ;;
    cloud-control)
      docker_compose_cmd --env-file "$(host_path "${PROJECT_ROOT}/control-node/env/cloud-control.env")" -f "$(host_path "${CONTROL_TEMPLATE}")" "$@"
      ;;
    cloud-lb-a)
      docker_compose_cmd --env-file "$(host_path "${PROJECT_ROOT}/lb-node/env/cloud-lb-a.env")" -f "$(host_path "${LB_TEMPLATE}")" "$@"
      ;;
    cloud-lb-b)
      docker_compose_cmd --env-file "$(host_path "${PROJECT_ROOT}/lb-node/env/cloud-lb-b.env")" -f "$(host_path "${LB_TEMPLATE}")" "$@"
      ;;
    minio-primary)
      docker_compose_cmd --profile admin --env-file "$(host_path "${PROJECT_ROOT}/storage-node/env/minio-primary.env")" -f "$(host_path "${STORAGE_TEMPLATE}")" "$@"
      ;;
    minio-secondary)
      docker_compose_cmd --env-file "$(host_path "${PROJECT_ROOT}/storage-node/env/minio-secondary.env")" -f "$(host_path "${STORAGE_TEMPLATE}")" "$@"
      ;;
    cloud-observability)
      docker_compose_cmd --env-file "$(host_path "${PROJECT_ROOT}/observability-node/env/cloud-observability.env")" -f "$(host_path "${OBSERVABILITY_TEMPLATE}")" "$@"
      ;;
    *)
      echo "Unknown node: ${node}" >&2
      return 1
      ;;
  esac
}

service_name_for_node() {
  local node="$1"

  case "${node}" in
    city-a|city-b)
      printf 'db\n'
      ;;
    city-a-local-lb|city-b-local-lb)
      printf 'local-lb\n'
      ;;
    cloud-control)
      printf 'etcd\n'
      ;;
    cloud-lb-a|cloud-lb-b)
      printf 'lb\n'
      ;;
    minio-primary|minio-secondary)
      printf 'minio\n'
      ;;
    cloud-observability)
      printf 'prometheus\n'
      ;;
    *)
      echo "Unknown node: ${node}" >&2
      return 1
      ;;
  esac
}

compose_exec() {
  local node="$1"
  shift
  local service
  service="$(service_name_for_node "${node}")"
  compose_node "${node}" exec -T "${service}" "$@"
}

compose_exec_service() {
  local node="$1"
  local service="$2"
  shift 2
  compose_node "${node}" exec -T "${service}" "$@"
}

compose_logs() {
  local node="$1"
  shift
  local service
  service="$(service_name_for_node "${node}")"
  compose_node "${node}" logs --no-color "$@" "${service}"
}

compose_logs_service() {
  local node="$1"
  local service="$2"
  shift 2
  compose_node "${node}" logs --no-color "$@" "${service}"
}

compose_up_node() {
  local node="$1"
  compose_node "${node}" up -d --build
}

compose_down_node() {
  local node="$1"
  compose_node "${node}" down
}

compose_start_node() {
  local node="$1"
  local service
  service="$(service_name_for_node "${node}")"
  compose_node "${node}" start "${service}"
}

compose_stop_node() {
  local node="$1"
  local service
  service="$(service_name_for_node "${node}")"
  compose_node "${node}" stop "${service}"
}

compose_kill_node() {
  local signal="$1"
  local node="$2"
  local service
  service="$(service_name_for_node "${node}")"
  compose_node "${node}" kill -s "${signal}" "${service}"
}

container_name_for_node() {
  local node="$1"

  case "${node}" in
    city-a)
      printf 'city-a-db\n'
      ;;
    city-b)
      printf 'city-b-db\n'
      ;;
    city-a-local-lb)
      printf 'city-a-local-lb\n'
      ;;
    city-b-local-lb)
      printf 'city-b-local-lb\n'
      ;;
    cloud-control)
      printf 'etcd-cloud\n'
      ;;
    cloud-lb-a)
      printf 'cloud-lb-a\n'
      ;;
    cloud-lb-b)
      printf 'cloud-lb-b\n'
      ;;
    minio-primary)
      printf 'minio-primary\n'
      ;;
    minio-secondary)
      printf 'minio-secondary\n'
      ;;
    cloud-observability)
      printf 'observability-prometheus\n'
      ;;
    *)
      echo "Unknown node: ${node}" >&2
      return 1
      ;;
  esac
}

role_of() {
  compose_exec "$1" sh -lc "curl -fs http://127.0.0.1:8008/patroni 2>/dev/null | sed -n 's/.*\"role\": \"\\([^\"]*\\)\".*/\\1/p'" 2>/dev/null || true
}

detect_primary() {
  local node

  for node in city-a city-b; do
    if [[ "$(role_of "${node}")" == "primary" ]]; then
      printf '%s\n' "${node}"
      return 0
    fi
  done

  return 1
}

detect_replica() {
  local node

  for node in city-a city-b; do
    if [[ "$(role_of "${node}")" == "replica" ]]; then
      printf '%s\n' "${node}"
      return 0
    fi
  done

  return 1
}

wait_for_role() {
  local node="$1"
  local expected_role="$2"
  local timeout="${3:-180}"
  local deadline=$((SECONDS + timeout))

  while (( SECONDS < deadline )); do
    if [[ "$(role_of "${node}")" == "${expected_role}" ]]; then
      return 0
    fi
    sleep 3
  done

  return 1
}

wait_for_cluster() {
  local timeout="${1:-240}"
  local deadline=$((SECONDS + timeout))

  while (( SECONDS < deadline )); do
    if detect_primary >/dev/null 2>&1 && detect_replica >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done

  return 1
}

ensure_network
