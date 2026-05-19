#!/bin/sh
set -eu

target="/etc/prometheus/prometheus.yml"

CLOUD_CONTROL_ETCD_SCRAPE_HOST="${CLOUD_CONTROL_ETCD_SCRAPE_HOST:-${CLOUD_CONTROL_HOST:-}}"
CLOUD_CONTROL_NODE_EXPORTER_SCRAPE_HOST="${CLOUD_CONTROL_NODE_EXPORTER_SCRAPE_HOST:-${CLOUD_CONTROL_HOST:-}}"
CLOUD_LB_A_NODE_EXPORTER_SCRAPE_HOST="${CLOUD_LB_A_NODE_EXPORTER_SCRAPE_HOST:-${CLOUD_LB_A_HOST:-}}"
MINIO_PRIMARY_API_SCRAPE_HOST="${MINIO_PRIMARY_API_SCRAPE_HOST:-${MINIO_PRIMARY_HOST:-}}"
MINIO_PRIMARY_NODE_EXPORTER_SCRAPE_HOST="${MINIO_PRIMARY_NODE_EXPORTER_SCRAPE_HOST:-${MINIO_PRIMARY_HOST:-}}"
MINIO_SECONDARY_API_SCRAPE_HOST="${MINIO_SECONDARY_API_SCRAPE_HOST:-${MINIO_SECONDARY_HOST:-}}"
MINIO_SECONDARY_NODE_EXPORTER_SCRAPE_HOST="${MINIO_SECONDARY_NODE_EXPORTER_SCRAPE_HOST:-${MINIO_SECONDARY_HOST:-}}"

append_target() {
  list="$1"
  item="$2"
  if [ -z "${item}" ]; then
    printf '%s' "${list}"
  elif [ -z "${list}" ]; then
    printf '%s' "${item}"
  else
    printf '%s %s' "${list}" "${item}"
  fi
}

build_legacy_targets() {
  kind="$1"
  targets=""

  for suffix in A B C D E F G H I J; do
    eval "host=\${CITY_${suffix}_HOST:-}"
    if [ -z "${host}" ]; then
      continue
    fi

    node="$(printf 'city-%s' "${suffix}" | tr 'A-Z' 'a-z')"
    case "${kind}" in
      postgres)
        eval "port=\${CITY_${suffix}_POSTGRES_EXPORTER_PORT:-}"
        ;;
      node)
        eval "port=\${CITY_${suffix}_NODE_EXPORTER_PORT:-}"
        ;;
      etcd)
        eval "port=\${CITY_${suffix}_ETCD_METRICS_PORT:-}"
        ;;
      *)
        echo "unknown legacy target kind: ${kind}" >&2
        exit 1
        ;;
    esac

    if [ -n "${port}" ]; then
      targets="$(append_target "${targets}" "${node}=${host}:${port}")"
    fi
  done

  printf '%s' "${targets}"
}

render_target_list() {
  targets="$1"
  role="$2"

  for item in $(printf '%s' "${targets}" | tr ',\n' '  '); do
    [ -n "${item}" ] || continue
    if [ "${item#*=}" != "${item}" ]; then
      node="${item%%=*}"
      endpoint="${item#*=}"
    else
      endpoint="${item}"
      node="${item%%:*}"
    fi

    if [ -z "${node}" ] || [ -z "${endpoint}" ]; then
      echo "invalid target item: ${item}" >&2
      exit 1
    fi

    cat <<EOF
      - targets:
          - ${endpoint}
        labels:
          node: ${node}
          role: ${role}
EOF
  done
}

render_optional_single_target() {
  node="$1"
  role="$2"
  endpoint="$3"

  if [ -n "${endpoint}" ]; then
    cat <<EOF
      - targets:
          - ${endpoint}
        labels:
          node: ${node}
          role: ${role}
EOF
  fi
}

POSTGRES_TARGETS="${POSTGRES_TARGETS:-$(build_legacy_targets postgres)}"
NODE_EXPORTER_TARGETS="${NODE_EXPORTER_TARGETS:-$(build_legacy_targets node)}"
ETCD_TARGETS="${ETCD_TARGETS:-$(build_legacy_targets etcd)}"
HAPROXY_TARGETS="${HAPROXY_TARGETS:-}"

if [ -n "${CLOUD_CONTROL_ETCD_SCRAPE_HOST}" ] && [ -n "${CLOUD_CONTROL_ETCD_METRICS_PORT:-}" ]; then
  ETCD_TARGETS="$(append_target "${ETCD_TARGETS}" "cloud-control=${CLOUD_CONTROL_ETCD_SCRAPE_HOST}:${CLOUD_CONTROL_ETCD_METRICS_PORT}")"
fi

if [ -n "${CLOUD_CONTROL_NODE_EXPORTER_SCRAPE_HOST}" ] && [ -n "${CLOUD_CONTROL_NODE_EXPORTER_PORT:-}" ]; then
  NODE_EXPORTER_TARGETS="$(append_target "${NODE_EXPORTER_TARGETS}" "cloud-control=${CLOUD_CONTROL_NODE_EXPORTER_SCRAPE_HOST}:${CLOUD_CONTROL_NODE_EXPORTER_PORT}")"
fi

if [ -n "${CLOUD_LB_A_HOST:-}" ]; then
  HAPROXY_TARGETS="$(append_target "${HAPROXY_TARGETS}" "cloud-lb-a=${CLOUD_LB_A_HOST}:${CLOUD_LB_A_METRICS_PORT}")"
  NODE_EXPORTER_TARGETS="$(append_target "${NODE_EXPORTER_TARGETS}" "cloud-lb-a=${CLOUD_LB_A_NODE_EXPORTER_SCRAPE_HOST}:${CLOUD_LB_A_NODE_EXPORTER_PORT}")"
fi

if [ -n "${CLOUD_LB_B_HOST:-}" ]; then
  HAPROXY_TARGETS="$(append_target "${HAPROXY_TARGETS}" "cloud-lb-b=${CLOUD_LB_B_HOST}:${CLOUD_LB_B_METRICS_PORT}")"
  NODE_EXPORTER_TARGETS="$(append_target "${NODE_EXPORTER_TARGETS}" "cloud-lb-b=${CLOUD_LB_B_HOST}:${CLOUD_LB_B_NODE_EXPORTER_PORT}")"
fi

if [ -n "${MINIO_SECONDARY_HOST:-}" ]; then
  NODE_EXPORTER_TARGETS="$(append_target "${NODE_EXPORTER_TARGETS}" "minio-secondary=${MINIO_SECONDARY_NODE_EXPORTER_SCRAPE_HOST}:${MINIO_SECONDARY_NODE_EXPORTER_PORT}")"
fi

if [ -n "${MINIO_PRIMARY_NODE_EXPORTER_SCRAPE_HOST}" ] && [ -n "${MINIO_PRIMARY_NODE_EXPORTER_PORT:-}" ]; then
  NODE_EXPORTER_TARGETS="$(append_target "${NODE_EXPORTER_TARGETS}" "minio-primary=${MINIO_PRIMARY_NODE_EXPORTER_SCRAPE_HOST}:${MINIO_PRIMARY_NODE_EXPORTER_PORT}")"
fi

cat > "${target}" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/alerts.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - 127.0.0.1:9090

  - job_name: etcd
    metrics_path: /metrics
    static_configs:
$(render_target_list "${ETCD_TARGETS}" etcd)

  - job_name: postgres_exporter
    static_configs:
$(render_target_list "${POSTGRES_TARGETS}" postgres)
EOF

if [ -n "${HAPROXY_TARGETS}" ]; then
  cat >> "${target}" <<EOF

  - job_name: haproxy
    metrics_path: /metrics
    static_configs:
$(render_target_list "${HAPROXY_TARGETS}" haproxy)
EOF
fi

cat >> "${target}" <<EOF

  - job_name: minio
    scheme: https
    metrics_path: /minio/v2/metrics/cluster
    tls_config:
      insecure_skip_verify: true
    static_configs:
$(render_optional_single_target minio-primary minio "${MINIO_PRIMARY_API_SCRAPE_HOST}:${MINIO_PRIMARY_API_PORT:-}")
$(render_optional_single_target minio-secondary minio "${MINIO_SECONDARY_API_SCRAPE_HOST:+${MINIO_SECONDARY_API_SCRAPE_HOST}:${MINIO_SECONDARY_API_PORT:-}}")

  - job_name: node_exporter
    static_configs:
$(render_target_list "${NODE_EXPORTER_TARGETS}" host)
EOF

if [ -n "${BACKUP_METRICS_TARGETS:-}" ]; then
  cat >> "${target}" <<EOF

  - job_name: belka_backup
    metrics_path: /metrics
    static_configs:
$(render_target_list "${BACKUP_METRICS_TARGETS}" backup)
EOF
fi

if [ "${PROMETHEUS_RENDER_ONLY:-false}" = "true" ]; then
  cat "${target}"
  exit 0
fi

exec /bin/prometheus \
  --config.file="${target}" \
  --web.enable-lifecycle \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time=3d \
  --web.console.libraries=/usr/share/prometheus/console_libraries \
  --web.console.templates=/usr/share/prometheus/consoles
