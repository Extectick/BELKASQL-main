#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage_common() {
  cat <<'EOF'
Usage:
  preflight-node.sh <role> <env-file> [--with-admin]
  deploy-node.sh <role> <env-file> [--with-admin]
  health-check-node.sh <role> <env-file> [--with-admin]

Roles:
  db-node
  control-node
  lb-node
  storage-node
  observability-node
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

note() {
  echo "==> $*"
}

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

parse_args() {
  [[ $# -ge 2 ]] || die "role and env-file are required"

  ROLE="$1"
  ENV_FILE_INPUT="$2"
  shift 2

  WITH_ADMIN=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --with-admin)
        WITH_ADMIN=1
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done

  case "${ROLE}" in
    db-node|control-node|lb-node|storage-node|observability-node)
      ;;
    *)
      usage_common
      die "unknown role: ${ROLE}"
      ;;
  esac

  if [[ "${ENV_FILE_INPUT}" = /* ]] || [[ "${ENV_FILE_INPUT}" =~ ^[A-Za-z]:[\\/].* ]]; then
    ENV_FILE="${ENV_FILE_INPUT}"
  else
    ENV_FILE="${PROJECT_ROOT}/${ENV_FILE_INPUT}"
  fi

  [[ -f "${ENV_FILE}" ]] || die "env file not found: ${ENV_FILE}"
}

load_env() {
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

template_for_role() {
  case "${ROLE}" in
    db-node)
      printf '%s\n' "${PROJECT_ROOT}/db-node/docker-compose.yml"
      ;;
    control-node)
      printf '%s\n' "${PROJECT_ROOT}/control-node/docker-compose.yml"
      ;;
    lb-node)
      printf '%s\n' "${PROJECT_ROOT}/lb-node/docker-compose.yml"
      ;;
    storage-node)
      printf '%s\n' "${PROJECT_ROOT}/storage-node/docker-compose.yml"
      ;;
    observability-node)
      printf '%s\n' "${PROJECT_ROOT}/observability-node/docker-compose.yml"
      ;;
  esac
}

prepare_compose() {
  COMPOSE_FILE="$(template_for_role)"
  [[ -f "${COMPOSE_FILE}" ]] || die "compose template not found: ${COMPOSE_FILE}"
}

compose_role() {
  local args=()

  if [[ "${ROLE}" == "storage-node" && "${WITH_ADMIN}" -eq 1 ]]; then
    args+=(--profile admin)
  fi

  docker_compose_cmd "${args[@]}" --env-file "$(host_path "${ENV_FILE}")" -f "$(host_path "${COMPOSE_FILE}")" "$@"
}

require_vars() {
  local missing=()
  local var

  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    printf 'Missing required variables in %s:\n' "${ENV_FILE}" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    exit 1
  fi
}

require_vars_if_set() {
  local anchor="$1"
  shift

  if [[ -n "${!anchor:-}" ]]; then
    require_vars "$@"
  fi
}

validate_role_env() {
  case "${ROLE}" in
    db-node)
      require_vars \
        COMPOSE_PROJECT_NAME BELKA_NETWORK_NAME INTERNAL_BIND_IP \
        ETCD_HEARTBEAT_INTERVAL ETCD_ELECTION_TIMEOUT \
        ETCD_CLIENT_PUBLISHED_PORT \
        ETCD_CONTAINER_NAME ETCD_HOSTNAME ETCD_NAME ETCD_ADVERTISE_HOST ETCD_IP ETCD_CLUSTER_TOKEN ETCD_INITIAL_CLUSTER \
        DB_CONTAINER_NAME DB_HOSTNAME DB_IP NODE_NAME NODE_API_HOST NODE_PG_HOST PATRONI_SCOPE \
        PATRONI_API_PUBLISHED_PORT PGBOUNCER_PUBLISHED_PORT \
        LOCAL_LB_CONTAINER_NAME LOCAL_LB_HOSTNAME LOCAL_LB_IP LOCAL_LB_WRITE_PUBLISHED_PORT LOCAL_LB_READ_PUBLISHED_PORT \
        POSTGRES_EXPORTER_CONTAINER_NAME POSTGRES_EXPORTER_PUBLISHED_PORT POSTGRES_EXPORTER_IP \
        NODE_EXPORTER_CONTAINER_NAME NODE_EXPORTER_PUBLISHED_PORT NODE_EXPORTER_IP \
        PROMTAIL_CONTAINER_NAME PROMTAIL_NODE_LABEL PROMTAIL_ROLE_LABEL PROMTAIL_IP LOKI_PUSH_URL \
        LOCAL_DB_HOST REMOTE_DB_HOST LOCAL_DB_DOMAIN \
        ETCD_HOST_1 ETCD_HOST_2 ETCD_HOST_3 \
        BACKREST_STANZA BACKREST_S3_BUCKET BACKREST_S3_ENDPOINT BACKREST_S3_KEY BACKREST_S3_SECRET BACKREST_S3_REGION \
        POSTGRES_SUPERUSER_PASSWORD REPLICATION_PASSWORD APP_USER_PASSWORD

      [[ "${LOCAL_DB_HOST}" != "${REMOTE_DB_HOST}" ]] || die "LOCAL_DB_HOST and REMOTE_DB_HOST must differ"
      [[ "${ETCD_INITIAL_CLUSTER}" == *"${ETCD_NAME}=http://${ETCD_ADVERTISE_HOST}:2380"* ]] || die "ETCD_INITIAL_CLUSTER must contain this node peer URL"
      ;;
    control-node)
      require_vars \
        COMPOSE_PROJECT_NAME BELKA_NETWORK_NAME INTERNAL_BIND_IP \
        ETCD_HEARTBEAT_INTERVAL ETCD_ELECTION_TIMEOUT \
        ETCD_CLIENT_PUBLISHED_PORT \
        ETCD_CONTAINER_NAME ETCD_HOSTNAME ETCD_NAME ETCD_ADVERTISE_HOST ETCD_IP ETCD_CLUSTER_TOKEN ETCD_INITIAL_CLUSTER \
        NODE_EXPORTER_CONTAINER_NAME NODE_EXPORTER_PUBLISHED_PORT NODE_EXPORTER_IP \
        PROMTAIL_CONTAINER_NAME PROMTAIL_NODE_LABEL PROMTAIL_ROLE_LABEL PROMTAIL_IP LOKI_PUSH_URL

      [[ "${ETCD_INITIAL_CLUSTER}" == *"${ETCD_NAME}=http://${ETCD_ADVERTISE_HOST}:2380"* ]] || die "ETCD_INITIAL_CLUSTER must contain this node peer URL"
      ;;
    lb-node)
      require_vars \
        COMPOSE_PROJECT_NAME BELKA_NETWORK_NAME \
        LB_CONTAINER_NAME LB_HOSTNAME LB_NAME LB_IP \
        KEEPALIVED_STATE KEEPALIVED_PRIORITY KEEPALIVED_PEER_IP KEEPALIVED_VIP KEEPALIVED_AUTH_PASS \
        DB_WRITE_DOMAIN DB_READ_DOMAIN DB_HOST_A DB_HOST_B \
        LB_WRITE_PUBLISHED_PORT LB_READ_PUBLISHED_PORT LB_METRICS_PUBLISHED_PORT \
        NODE_EXPORTER_CONTAINER_NAME NODE_EXPORTER_PUBLISHED_PORT NODE_EXPORTER_IP \
        PROMTAIL_CONTAINER_NAME PROMTAIL_NODE_LABEL PROMTAIL_ROLE_LABEL PROMTAIL_IP LOKI_PUSH_URL

      [[ "${KEEPALIVED_STATE}" == "MASTER" || "${KEEPALIVED_STATE}" == "BACKUP" ]] || die "KEEPALIVED_STATE must be MASTER or BACKUP"
      [[ "${DB_HOST_A}" != "${DB_HOST_B}" ]] || die "DB_HOST_A and DB_HOST_B must differ"
      ;;
    storage-node)
      require_vars \
        COMPOSE_PROJECT_NAME BELKA_NETWORK_NAME INTERNAL_BIND_IP \
        MINIO_CONTAINER_NAME MINIO_HOSTNAME MINIO_IP \
        MINIO_ROOT_USER MINIO_ROOT_PASSWORD MINIO_BROWSER_REDIRECT_URL MINIO_API_PUBLISHED_PORT MINIO_CONSOLE_PUBLISHED_PORT \
        NODE_EXPORTER_CONTAINER_NAME NODE_EXPORTER_PUBLISHED_PORT NODE_EXPORTER_IP \
        PROMTAIL_CONTAINER_NAME PROMTAIL_NODE_LABEL PROMTAIL_ROLE_LABEL PROMTAIL_IP LOKI_PUSH_URL \
        PGBACKREST_S3_BUCKET

      if [[ "${WITH_ADMIN}" -eq 1 ]]; then
        require_vars \
          MINIO_ADMIN_CONTAINER_NAME MINIO_ADMIN_HOSTNAME MINIO_ADMIN_IP \
          MINIO_MIRROR_CONTAINER_NAME MINIO_MIRROR_HOSTNAME MINIO_MIRROR_IP \
          MINIO_PRIMARY_HOST MINIO_PRIMARY_ROOT_USER MINIO_PRIMARY_ROOT_PASSWORD \
          MINIO_SECONDARY_HOST MINIO_SECONDARY_ROOT_USER MINIO_SECONDARY_ROOT_PASSWORD
      fi
      ;;
    observability-node)
      require_vars \
        COMPOSE_PROJECT_NAME BELKA_NETWORK_NAME INTERNAL_BIND_IP \
        PROMETHEUS_CONTAINER_NAME PROMETHEUS_HOSTNAME PROMETHEUS_PUBLISHED_PORT \
        LOKI_CONTAINER_NAME LOKI_HOSTNAME LOKI_PUBLISHED_PORT \
        ALERTMANAGER_CONTAINER_NAME ALERTMANAGER_HOSTNAME ALERTMANAGER_PUBLISHED_PORT \
        GRAFANA_CONTAINER_NAME GRAFANA_HOSTNAME GRAFANA_PUBLISHED_PORT GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD GRAFANA_ROOT_URL \
        CITY_A_HOST CITY_A_ETCD_METRICS_PORT CITY_A_POSTGRES_EXPORTER_PORT CITY_A_NODE_EXPORTER_PORT \
        CITY_B_HOST CITY_B_ETCD_METRICS_PORT CITY_B_POSTGRES_EXPORTER_PORT CITY_B_NODE_EXPORTER_PORT \
        CLOUD_CONTROL_HOST CLOUD_CONTROL_ETCD_METRICS_PORT CLOUD_CONTROL_NODE_EXPORTER_PORT \
        MINIO_PRIMARY_HOST MINIO_PRIMARY_API_PORT MINIO_PRIMARY_NODE_EXPORTER_PORT

      require_vars_if_set CLOUD_LB_A_HOST CLOUD_LB_A_HOST CLOUD_LB_A_METRICS_PORT CLOUD_LB_A_NODE_EXPORTER_PORT
      require_vars_if_set CLOUD_LB_B_HOST CLOUD_LB_B_HOST CLOUD_LB_B_METRICS_PORT CLOUD_LB_B_NODE_EXPORTER_PORT
      require_vars_if_set MINIO_SECONDARY_HOST MINIO_SECONDARY_HOST MINIO_SECONDARY_API_PORT MINIO_SECONDARY_NODE_EXPORTER_PORT
      ;;
  esac
}

ensure_docker_ready() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"
  docker_cmd info >/dev/null 2>&1 || die "docker daemon is not reachable"
}

ensure_network() {
  if [[ -n "${BELKA_NETWORK_NAME:-}" ]] && ! docker_cmd network inspect "${BELKA_NETWORK_NAME}" >/dev/null 2>&1; then
    note "Creating docker network ${BELKA_NETWORK_NAME}"
    docker_cmd network create --driver bridge --subnet 172.28.0.0/16 "${BELKA_NETWORK_NAME}" >/dev/null
  fi
}

run_compose_validation() {
  note "Validating compose template"
  compose_role config -q
}

print_role_summary() {
  case "${ROLE}" in
    db-node)
      cat <<EOF
Role summary:
  Compose project: ${COMPOSE_PROJECT_NAME}
  Local DB host: ${LOCAL_DB_HOST}
  Remote DB host: ${REMOTE_DB_HOST}
  Local DB domain: ${LOCAL_DB_DOMAIN}
  Published Patroni API port: ${PATRONI_API_PUBLISHED_PORT}
  Published PgBouncer port: ${PGBOUNCER_PUBLISHED_PORT}
  etcd peers: ${ETCD_HOST_1}, ${ETCD_HOST_2}, ${ETCD_HOST_3}
  Backup endpoint: ${BACKREST_S3_ENDPOINT}
EOF
      ;;
    control-node)
      cat <<EOF
Role summary:
  Compose project: ${COMPOSE_PROJECT_NAME}
  etcd name: ${ETCD_NAME}
  advertise host: ${ETCD_ADVERTISE_HOST}
  initial cluster: ${ETCD_INITIAL_CLUSTER}
EOF
      ;;
    lb-node)
      cat <<EOF
Role summary:
  Compose project: ${COMPOSE_PROJECT_NAME}
  LB name: ${LB_NAME}
  Keepalived state: ${KEEPALIVED_STATE}
  DB hosts: ${DB_HOST_A}, ${DB_HOST_B}
  Domains: ${DB_WRITE_DOMAIN}, ${DB_READ_DOMAIN}
EOF
      ;;
    storage-node)
      cat <<EOF
Role summary:
  Compose project: ${COMPOSE_PROJECT_NAME}
  MinIO host: ${MINIO_HOSTNAME}
  Bucket: ${PGBACKREST_S3_BUCKET}
  Primary host: ${MINIO_PRIMARY_HOST:-n/a}
  Secondary host: ${MINIO_SECONDARY_HOST:-disabled}
  Admin profile: $([[ "${WITH_ADMIN}" -eq 1 ]] && printf yes || printf no)
EOF
      ;;
    observability-node)
      cat <<EOF
Role summary:
  Compose project: ${COMPOSE_PROJECT_NAME}
  Prometheus port: ${PROMETHEUS_PUBLISHED_PORT}
  Alertmanager port: ${ALERTMANAGER_PUBLISHED_PORT}
  Grafana port: ${GRAFANA_PUBLISHED_PORT}
  Loki port: ${LOKI_PUBLISHED_PORT}
  Primary DB metrics target: ${CITY_A_HOST}:${CITY_A_POSTGRES_EXPORTER_PORT}
  Secondary DB metrics target: ${CITY_B_HOST}:${CITY_B_POSTGRES_EXPORTER_PORT}
EOF
      ;;
  esac
}

run_preflight() {
  ensure_docker_ready
  validate_role_env
  ensure_network
  run_compose_validation
  print_role_summary
}
