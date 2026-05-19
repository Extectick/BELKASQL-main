#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

note() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

run_step() {
  note "$*"
  (
    cd "${PROJECT_ROOT}"
    "$@"
  )
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

random_secret() {
  local length="${1:-24}"

  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${length}"
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${length}"
  fi
}

prompt_value() {
  local var_name="$1"
  local label="$2"
  local default_value="${3:-}"
  local value=""

  while true; do
    if [[ -n "${default_value}" ]]; then
      read -r -p "${label} [${default_value}]: " value
      value="$(trim "${value}")"
      if [[ -z "${value}" ]]; then
        value="${default_value}"
      fi
    else
      read -r -p "${label}: " value
      value="$(trim "${value}")"
    fi

    if [[ -n "${value}" ]]; then
      printf -v "${var_name}" '%s' "${value}"
      return 0
    fi

    warn "value cannot be empty"
  done
}

prompt_optional() {
  local var_name="$1"
  local label="$2"
  local default_value="${3:-}"
  local value=""

  if [[ -n "${default_value}" ]]; then
    read -r -p "${label} [${default_value}]: " value
    value="$(trim "${value}")"
    if [[ -z "${value}" ]]; then
      value="${default_value}"
    fi
  else
    read -r -p "${label} (leave empty to skip): " value
    value="$(trim "${value}")"
  fi

  printf -v "${var_name}" '%s' "${value}"
}

prompt_secret() {
  local var_name="$1"
  local label="$2"
  local suggested="${3:-}"
  local value=""

  if [[ -n "${suggested}" ]]; then
    read -r -s -p "${label} [Enter = auto-generate]: " value
    printf '\n'
    value="$(trim "${value}")"
    if [[ -z "${value}" ]]; then
      value="${suggested}"
      note "${label}: generated automatically"
    fi
  else
    while true; do
      read -r -s -p "${label}: " value
      printf '\n'
      value="$(trim "${value}")"
      if [[ -n "${value}" ]]; then
        break
      fi
      warn "value cannot be empty"
    done
  fi

  printf -v "${var_name}" '%s' "${value}"
}

prompt_yes_no() {
  local var_name="$1"
  local label="$2"
  local default_value="${3:-y}"
  local answer=""

  while true; do
    read -r -p "${label} [${default_value}]: " answer
    answer="$(trim "${answer}")"
    if [[ -z "${answer}" ]]; then
      answer="${default_value}"
    fi

    case "${answer}" in
      y|Y|yes|YES)
        printf -v "${var_name}" '1'
        return 0
        ;;
      n|N|no|NO)
        printf -v "${var_name}" '0'
        return 0
        ;;
      *)
        warn "please answer y or n"
        ;;
    esac
  done
}

prompt_deploy_role() {
  local var_name="$1"
  local answer=""

  printf '\n'
  printf 'Choose what this host should do now:\n'
  printf '  1) config-only\n'
  printf '  2) city-a db-node\n'
  printf '  3) city-b db-node\n'
  printf '  4) cloud control-node\n'
  printf '  5) cloud storage-node\n'
  printf '  6) cloud observability-node\n'

  while true; do
    read -r -p "Selection [1]: " answer
    answer="$(trim "${answer}")"
    if [[ -z "${answer}" ]]; then
      answer="1"
    fi

    case "${answer}" in
      1|config-only)
        printf -v "${var_name}" '%s' 'config-only'
        return 0
        ;;
      2|city-a)
        printf -v "${var_name}" '%s' 'city-a'
        return 0
        ;;
      3|city-b)
        printf -v "${var_name}" '%s' 'city-b'
        return 0
        ;;
      4|cloud-control)
        printf -v "${var_name}" '%s' 'cloud-control'
        return 0
        ;;
      5|cloud-storage)
        printf -v "${var_name}" '%s' 'cloud-storage'
        return 0
        ;;
      6|cloud-observability)
        printf -v "${var_name}" '%s' 'cloud-observability'
        return 0
        ;;
      *)
        warn "please choose 1-6"
        ;;
    esac
  done
}

backup_if_exists() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    cp "${path}" "${path}.bak-${TIMESTAMP}"
  fi
}

write_env_from_stdin() {
  local path="$1"
  mkdir -p "$(dirname "${path}")"
  backup_if_exists "${path}"
  cat > "${path}"
}

write_secret_summary() {
  local path="${PROJECT_ROOT}/docs/generated/db-ingress-secrets-${TIMESTAMP}.txt"
  mkdir -p "$(dirname "${path}")"
  umask 077
  cat > "${path}" <<EOF
Generated at: ${TIMESTAMP}

DB_WRITE_DOMAIN=${DB_WRITE_DOMAIN}
DB_READ_DOMAIN=${DB_READ_DOMAIN}

POSTGRES_SUPERUSER_PASSWORD=${POSTGRES_SUPERUSER_PASSWORD}
REPLICATION_PASSWORD=${REPLICATION_PASSWORD}
APP_USER_PASSWORD=${APP_USER_PASSWORD}

MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}

GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}

ETCD_CLUSTER_TOKEN=${ETCD_CLUSTER_TOKEN}
EOF
  chmod 600 "${path}"
  SECRET_SUMMARY_PATH="${path}"
}

validate_ip_like() {
  local label="$1"
  local value="$2"

  if [[ ! "${value}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    die "${label} contains unsupported characters: ${value}"
  fi
}

deploy_selected_role() {
  local compose_role=""
  local env_file=""

  case "${DEPLOY_ROLE}" in
    config-only)
      note "Config files were generated only. No deploy requested."
      return 0
      ;;
    city-a)
      compose_role="db-node"
      env_file="db-node/env/city-a.env"
      ;;
    city-b)
      compose_role="db-node"
      env_file="db-node/env/city-b.env"
      ;;
    cloud-control)
      compose_role="control-node"
      env_file="control-node/env/cloud-control.env"
      ;;
    cloud-storage)
      compose_role="storage-node"
      env_file="storage-node/env/minio-primary.env"
      ;;
    cloud-observability)
      compose_role="observability-node"
      env_file="observability-node/env/cloud-observability.env"
      ;;
    *)
      die "unknown deploy role: ${DEPLOY_ROLE}"
      ;;
  esac

  require_command docker

  run_step bash "./preflight-node.sh" "${compose_role}" "${env_file}"
  run_step bash "./deploy-node.sh" "${compose_role}" "${env_file}"

  if [[ "${RUN_HEALTHCHECK}" -eq 1 ]]; then
    run_step bash "./health-check-node.sh" "${compose_role}" "${env_file}"
  else
    note "Health check skipped for ${DEPLOY_ROLE}"
  fi
}

render_files() {
  local loki_push_url="http://${CLOUD_PRIVATE_IP}:3100/loki/api/v1/push"
  local cloud_etcd_cluster="etcd-city-a=http://${CITY_A_PRIVATE_IP}:2380,etcd-city-b=http://${CITY_B_PRIVATE_IP}:2380,etcd-cloud=http://${CLOUD_PRIVATE_IP}:2380"

  write_env_from_stdin "${PROJECT_ROOT}/control-node/env/cloud-control.env" <<EOF
COMPOSE_PROJECT_NAME=cloud-control
BELKA_NETWORK_NAME=belkasql_belka-net
ETCD_HEARTBEAT_INTERVAL=2000
ETCD_ELECTION_TIMEOUT=10000
ETCD_CLIENT_PUBLISHED_PORT=2379

ETCD_CONTAINER_NAME=etcd-cloud
ETCD_HOSTNAME=etcd-cloud
ETCD_NAME=etcd-cloud
ETCD_ADVERTISE_HOST=${CLOUD_PRIVATE_IP}
ETCD_IP=172.28.0.13
ETCD_CLUSTER_TOKEN=${ETCD_CLUSTER_TOKEN}
ETCD_INITIAL_CLUSTER=${cloud_etcd_cluster}
NODE_EXPORTER_CONTAINER_NAME=cloud-control-node-exporter
NODE_EXPORTER_PUBLISHED_PORT=9100
NODE_EXPORTER_IP=172.28.0.71
PROMTAIL_CONTAINER_NAME=cloud-control-promtail
PROMTAIL_NODE_LABEL=cloud-control
PROMTAIL_ROLE_LABEL=control-node
PROMTAIL_IP=172.28.0.72
LOKI_PUSH_URL=${loki_push_url}
EOF

  write_env_from_stdin "${PROJECT_ROOT}/db-node/env/city-a.env" <<EOF
COMPOSE_PROJECT_NAME=city-a
BELKA_NETWORK_NAME=belkasql_belka-net
ETCD_HEARTBEAT_INTERVAL=2000
ETCD_ELECTION_TIMEOUT=10000
ETCD_CLIENT_PUBLISHED_PORT=2379

ETCD_CONTAINER_NAME=etcd-city-a
ETCD_HOSTNAME=etcd-city-a
ETCD_NAME=etcd-city-a
ETCD_ADVERTISE_HOST=${CITY_A_PRIVATE_IP}
ETCD_IP=172.28.0.23
ETCD_CLUSTER_TOKEN=${ETCD_CLUSTER_TOKEN}
ETCD_INITIAL_CLUSTER=${cloud_etcd_cluster}

DB_CONTAINER_NAME=city-a-db
DB_HOSTNAME=city-a-db
DB_IP=172.28.0.21
NODE_NAME=city-a-db
NODE_API_HOST=${CITY_A_PRIVATE_IP}
NODE_PG_HOST=${CITY_A_PRIVATE_IP}
PATRONI_SCOPE=${PATRONI_SCOPE}
PATRONI_API_PUBLISHED_PORT=8008
PGBOUNCER_PUBLISHED_PORT=6432
LOCAL_LB_CONTAINER_NAME=city-a-local-lb
LOCAL_LB_HOSTNAME=city-a-local-lb
LOCAL_LB_IP=172.28.0.22
LOCAL_LB_WRITE_PUBLISHED_PORT=5000
LOCAL_LB_READ_PUBLISHED_PORT=5001
POSTGRES_EXPORTER_CONTAINER_NAME=city-a-postgres-exporter
POSTGRES_EXPORTER_PUBLISHED_PORT=9187
POSTGRES_EXPORTER_IP=172.28.0.73
NODE_EXPORTER_CONTAINER_NAME=city-a-node-exporter
NODE_EXPORTER_PUBLISHED_PORT=9100
NODE_EXPORTER_IP=172.28.0.74
PROMTAIL_CONTAINER_NAME=city-a-promtail
PROMTAIL_NODE_LABEL=city-a
PROMTAIL_ROLE_LABEL=db-node
PROMTAIL_IP=172.28.0.75
LOKI_PUSH_URL=${loki_push_url}
LOCAL_DB_HOST=city-a-db
REMOTE_DB_HOST=${CITY_B_PRIVATE_IP}
LOCAL_DB_DOMAIN=${CITY_A_LOCAL_DOMAIN}

ETCD_HOST_1=etcd-city-a
ETCD_HOST_2=${CITY_B_PRIVATE_IP}
ETCD_HOST_3=${CLOUD_PRIVATE_IP}

BACKREST_STANZA=${BACKREST_STANZA}
BACKREST_S3_BUCKET=${PGBACKREST_BUCKET}
BACKREST_S3_ENDPOINT=${CLOUD_PRIVATE_IP}
BACKREST_S3_KEY=${MINIO_ROOT_USER}
BACKREST_S3_SECRET=${MINIO_ROOT_PASSWORD}
BACKREST_S3_REGION=${BACKREST_S3_REGION}
BACKREST_S3_PORT=9000
BACKREST_S3_VERIFY_TLS=n

POSTGRES_SUPERUSER_PASSWORD=${POSTGRES_SUPERUSER_PASSWORD}
REPLICATION_PASSWORD=${REPLICATION_PASSWORD}
APP_USER_PASSWORD=${APP_USER_PASSWORD}
EOF

  write_env_from_stdin "${PROJECT_ROOT}/db-node/env/city-b.env" <<EOF
COMPOSE_PROJECT_NAME=city-b
BELKA_NETWORK_NAME=belkasql_belka-net
ETCD_HEARTBEAT_INTERVAL=2000
ETCD_ELECTION_TIMEOUT=10000
ETCD_CLIENT_PUBLISHED_PORT=2379

ETCD_CONTAINER_NAME=etcd-city-b
ETCD_HOSTNAME=etcd-city-b
ETCD_NAME=etcd-city-b
ETCD_ADVERTISE_HOST=${CITY_B_PRIVATE_IP}
ETCD_IP=172.28.0.33
ETCD_CLUSTER_TOKEN=${ETCD_CLUSTER_TOKEN}
ETCD_INITIAL_CLUSTER=${cloud_etcd_cluster}

DB_CONTAINER_NAME=city-b-db
DB_HOSTNAME=city-b-db
DB_IP=172.28.0.31
NODE_NAME=city-b-db
NODE_API_HOST=${CITY_B_PRIVATE_IP}
NODE_PG_HOST=${CITY_B_PRIVATE_IP}
PATRONI_SCOPE=${PATRONI_SCOPE}
PATRONI_API_PUBLISHED_PORT=8008
PGBOUNCER_PUBLISHED_PORT=6432
LOCAL_LB_CONTAINER_NAME=city-b-local-lb
LOCAL_LB_HOSTNAME=city-b-local-lb
LOCAL_LB_IP=172.28.0.32
LOCAL_LB_WRITE_PUBLISHED_PORT=5000
LOCAL_LB_READ_PUBLISHED_PORT=5001
POSTGRES_EXPORTER_CONTAINER_NAME=city-b-postgres-exporter
POSTGRES_EXPORTER_PUBLISHED_PORT=9187
POSTGRES_EXPORTER_IP=172.28.0.76
NODE_EXPORTER_CONTAINER_NAME=city-b-node-exporter
NODE_EXPORTER_PUBLISHED_PORT=9100
NODE_EXPORTER_IP=172.28.0.77
PROMTAIL_CONTAINER_NAME=city-b-promtail
PROMTAIL_NODE_LABEL=city-b
PROMTAIL_ROLE_LABEL=db-node
PROMTAIL_IP=172.28.0.78
LOKI_PUSH_URL=${loki_push_url}
LOCAL_DB_HOST=city-b-db
REMOTE_DB_HOST=${CITY_A_PRIVATE_IP}
LOCAL_DB_DOMAIN=${CITY_B_LOCAL_DOMAIN}

ETCD_HOST_1=${CITY_A_PRIVATE_IP}
ETCD_HOST_2=etcd-city-b
ETCD_HOST_3=${CLOUD_PRIVATE_IP}

BACKREST_STANZA=${BACKREST_STANZA}
BACKREST_S3_BUCKET=${PGBACKREST_BUCKET}
BACKREST_S3_ENDPOINT=${CLOUD_PRIVATE_IP}
BACKREST_S3_KEY=${MINIO_ROOT_USER}
BACKREST_S3_SECRET=${MINIO_ROOT_PASSWORD}
BACKREST_S3_REGION=${BACKREST_S3_REGION}
BACKREST_S3_PORT=9000
BACKREST_S3_VERIFY_TLS=n

POSTGRES_SUPERUSER_PASSWORD=${POSTGRES_SUPERUSER_PASSWORD}
REPLICATION_PASSWORD=${REPLICATION_PASSWORD}
APP_USER_PASSWORD=${APP_USER_PASSWORD}
EOF

  write_env_from_stdin "${PROJECT_ROOT}/storage-node/env/minio-primary.env" <<EOF
COMPOSE_PROJECT_NAME=minio-primary
BELKA_NETWORK_NAME=belkasql_belka-net

MINIO_CONTAINER_NAME=minio-primary
MINIO_HOSTNAME=minio-primary
MINIO_IP=172.28.0.41
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
MINIO_BROWSER_REDIRECT_URL=${MINIO_BROWSER_REDIRECT_URL}
MINIO_API_PUBLISHED_PORT=9000
MINIO_CONSOLE_PUBLISHED_PORT=9001
NODE_EXPORTER_CONTAINER_NAME=minio-primary-node-exporter
NODE_EXPORTER_PUBLISHED_PORT=9101
NODE_EXPORTER_IP=172.28.0.83
PROMTAIL_CONTAINER_NAME=minio-primary-promtail
PROMTAIL_NODE_LABEL=minio-primary
PROMTAIL_ROLE_LABEL=storage-node
PROMTAIL_IP=172.28.0.84
LOKI_PUSH_URL=${loki_push_url}

MINIO_ADMIN_CONTAINER_NAME=minio-admin
MINIO_ADMIN_HOSTNAME=minio-admin
MINIO_ADMIN_IP=172.28.0.43
MINIO_MIRROR_CONTAINER_NAME=minio-mirror
MINIO_MIRROR_HOSTNAME=minio-mirror
MINIO_MIRROR_IP=172.28.0.44

MINIO_PRIMARY_HOST=${CLOUD_PRIVATE_IP}
MINIO_PRIMARY_ROOT_USER=${MINIO_ROOT_USER}
MINIO_PRIMARY_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
MINIO_SECONDARY_HOST=
MINIO_SECONDARY_ROOT_USER=
MINIO_SECONDARY_ROOT_PASSWORD=
PGBACKREST_S3_BUCKET=${PGBACKREST_BUCKET}
EOF

  write_env_from_stdin "${PROJECT_ROOT}/observability-node/env/cloud-observability.env" <<EOF
COMPOSE_PROJECT_NAME=cloud-observability
BELKA_NETWORK_NAME=belkasql_belka-net

PROMETHEUS_CONTAINER_NAME=observability-prometheus
PROMETHEUS_HOSTNAME=observability-prometheus
PROMETHEUS_PUBLISHED_PORT=9090

LOKI_CONTAINER_NAME=observability-loki
LOKI_HOSTNAME=observability-loki
LOKI_PUBLISHED_PORT=3100

ALERTMANAGER_CONTAINER_NAME=observability-alertmanager
ALERTMANAGER_HOSTNAME=observability-alertmanager
ALERTMANAGER_PUBLISHED_PORT=9093

GRAFANA_CONTAINER_NAME=observability-grafana
GRAFANA_HOSTNAME=observability-grafana
GRAFANA_PUBLISHED_PORT=3000
GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
GRAFANA_ROOT_URL=${GRAFANA_ROOT_URL}

ETCD_TARGETS=city-a=${CITY_A_PRIVATE_IP}:2379 city-b=${CITY_B_PRIVATE_IP}:2379
POSTGRES_TARGETS=city-a=${CITY_A_PRIVATE_IP}:9187 city-b=${CITY_B_PRIVATE_IP}:9187
NODE_EXPORTER_TARGETS=city-a=${CITY_A_PRIVATE_IP}:9100 city-b=${CITY_B_PRIVATE_IP}:9100

CLOUD_CONTROL_HOST=${CLOUD_PRIVATE_IP}
CLOUD_CONTROL_ETCD_METRICS_PORT=2379
CLOUD_CONTROL_NODE_EXPORTER_PORT=9100

CLOUD_LB_A_HOST=
CLOUD_LB_A_METRICS_PORT=
CLOUD_LB_A_NODE_EXPORTER_PORT=

CLOUD_LB_B_HOST=
CLOUD_LB_B_METRICS_PORT=
CLOUD_LB_B_NODE_EXPORTER_PORT=

MINIO_PRIMARY_HOST=${CLOUD_PRIVATE_IP}
MINIO_PRIMARY_API_PORT=9000
MINIO_PRIMARY_NODE_EXPORTER_PORT=9101

MINIO_SECONDARY_HOST=
MINIO_SECONDARY_API_PORT=
MINIO_SECONDARY_NODE_EXPORTER_PORT=
EOF
}

print_summary() {
  cat <<EOF

Configuration files written:
  - control-node/env/cloud-control.env
  - db-node/env/city-a.env
  - db-node/env/city-b.env
  - storage-node/env/minio-primary.env
  - observability-node/env/cloud-observability.env

Secrets summary:
  - ${SECRET_SUMMARY_PATH}

Recommended DNS:
  - ${DB_WRITE_DOMAIN} -> ${CITY_A_PUBLIC_IP}
  - ${DB_WRITE_DOMAIN} -> ${CITY_B_PUBLIC_IP}
  - ${DB_READ_DOMAIN}  -> ${CITY_A_PUBLIC_IP}
  - ${DB_READ_DOMAIN}  -> ${CITY_B_PUBLIC_IP}

Suggested deploy order:
  1. cloud:   bash ./preflight-node.sh control-node control-node/env/cloud-control.env
  2. cloud:   bash ./deploy-node.sh control-node control-node/env/cloud-control.env
  3. cloud:   bash ./preflight-node.sh storage-node storage-node/env/minio-primary.env
  4. cloud:   bash ./deploy-node.sh storage-node storage-node/env/minio-primary.env
  5. city-a:  bash ./preflight-node.sh db-node db-node/env/city-a.env
  6. city-a:  bash ./deploy-node.sh db-node db-node/env/city-a.env
  7. city-b:  bash ./preflight-node.sh db-node db-node/env/city-b.env
  8. city-b:  bash ./deploy-node.sh db-node db-node/env/city-b.env
  9. cloud:   bash ./health-check-node.sh control-node control-node/env/cloud-control.env
 10. cloud:   bash ./preflight-node.sh observability-node observability-node/env/cloud-observability.env
 11. cloud:   bash ./deploy-node.sh observability-node observability-node/env/cloud-observability.env

Runbook:
  - docs/INSTALL_DB_INGRESS.md

Local action selected:
  - ${DEPLOY_ROLE}
EOF
}

main() {
  require_command bash
  require_command sed
  require_command date

  note "BELKASQL DB-ingress production bootstrap"
  note "This wizard writes env files for the 3-host profile: city-a, city-b, cloud"
  printf '\n'

  prompt_value CITY_A_PRIVATE_IP "City A private IP or internal DNS name"
  prompt_value CITY_B_PRIVATE_IP "City B private IP or internal DNS name"
  prompt_value CLOUD_PRIVATE_IP "Cloud private IP or internal DNS name"
  prompt_value CITY_A_PUBLIC_IP "City A public IP"
  prompt_value CITY_B_PUBLIC_IP "City B public IP"

  validate_ip_like "City A private IP" "${CITY_A_PRIVATE_IP}"
  validate_ip_like "City B private IP" "${CITY_B_PRIVATE_IP}"
  validate_ip_like "Cloud private IP" "${CLOUD_PRIVATE_IP}"
  validate_ip_like "City A public IP" "${CITY_A_PUBLIC_IP}"
  validate_ip_like "City B public IP" "${CITY_B_PUBLIC_IP}"

  prompt_value DB_WRITE_DOMAIN "Write domain" "db-write.example.com"
  prompt_value DB_READ_DOMAIN "Read domain" "db-read.example.com"
  prompt_value CITY_A_LOCAL_DOMAIN "City A local internal alias" "db-city-a.example.internal"
  prompt_value CITY_B_LOCAL_DOMAIN "City B local internal alias" "db-city-b.example.internal"

  prompt_value PATRONI_SCOPE "Patroni scope" "belka-ha"
  prompt_value BACKREST_STANZA "pgBackRest stanza" "belka"
  prompt_value PGBACKREST_BUCKET "pgBackRest bucket" "belka-pgbackrest"
  prompt_value BACKREST_S3_REGION "S3 region" "us-east-1"
  prompt_optional GRAFANA_ROOT_URL "Grafana root URL" "http://${CLOUD_PRIVATE_IP}:3000"
  prompt_optional MINIO_BROWSER_REDIRECT_URL "MinIO console URL" "http://${CLOUD_PRIVATE_IP}:9001"

  prompt_secret POSTGRES_SUPERUSER_PASSWORD "Postgres superuser password" "$(random_secret 24)"
  prompt_secret REPLICATION_PASSWORD "Replication password" "$(random_secret 24)"
  prompt_secret APP_USER_PASSWORD "App user password" "$(random_secret 24)"
  prompt_value MINIO_ROOT_USER "MinIO access key" "minioadmin"
  prompt_secret MINIO_ROOT_PASSWORD "MinIO secret key" "$(random_secret 24)"
  prompt_value GRAFANA_ADMIN_USER "Grafana admin user" "admin"
  prompt_secret GRAFANA_ADMIN_PASSWORD "Grafana admin password" "$(random_secret 24)"
  prompt_secret ETCD_CLUSTER_TOKEN "etcd cluster token" "$(random_secret 20)"

  prompt_deploy_role DEPLOY_ROLE
  if [[ "${DEPLOY_ROLE}" != "config-only" ]]; then
    if [[ "${DEPLOY_ROLE}" == "cloud-control" ]]; then
      prompt_yes_no RUN_HEALTHCHECK "Run health-check for cloud-control now? Usually better after both DB nodes join." "n"
    else
      prompt_yes_no RUN_HEALTHCHECK "Run health-check after deploy on this host?" "y"
    fi
  else
    RUN_HEALTHCHECK=0
  fi

  prompt_yes_no CONTINUE_WRITE "Write/overwrite env files now?" "y"
  [[ "${CONTINUE_WRITE}" -eq 1 ]] || die "cancelled"

  render_files
  write_secret_summary
  print_summary
  deploy_selected_role
}

main "$@"
