#!/bin/sh
set -eu

target="/etc/prometheus/prometheus.yml"

CLOUD_CONTROL_ETCD_SCRAPE_HOST="${CLOUD_CONTROL_ETCD_SCRAPE_HOST:-${CLOUD_CONTROL_HOST}}"
CLOUD_CONTROL_NODE_EXPORTER_SCRAPE_HOST="${CLOUD_CONTROL_NODE_EXPORTER_SCRAPE_HOST:-${CLOUD_CONTROL_HOST}}"
MINIO_PRIMARY_API_SCRAPE_HOST="${MINIO_PRIMARY_API_SCRAPE_HOST:-${MINIO_PRIMARY_HOST}}"
MINIO_PRIMARY_NODE_EXPORTER_SCRAPE_HOST="${MINIO_PRIMARY_NODE_EXPORTER_SCRAPE_HOST:-${MINIO_PRIMARY_HOST}}"
MINIO_SECONDARY_API_SCRAPE_HOST="${MINIO_SECONDARY_API_SCRAPE_HOST:-${MINIO_SECONDARY_HOST:-}}"
MINIO_SECONDARY_NODE_EXPORTER_SCRAPE_HOST="${MINIO_SECONDARY_NODE_EXPORTER_SCRAPE_HOST:-${MINIO_SECONDARY_HOST:-}}"

render_haproxy_job() {
  if [ -z "${CLOUD_LB_A_HOST:-}" ] && [ -z "${CLOUD_LB_B_HOST:-}" ]; then
    return 0
  fi

  cat <<EOF
  - job_name: haproxy
    metrics_path: /metrics
    static_configs:
EOF

  if [ -n "${CLOUD_LB_A_HOST:-}" ]; then
    cat <<EOF
      - targets:
          - ${CLOUD_LB_A_HOST}:${CLOUD_LB_A_METRICS_PORT}
        labels:
          node: cloud-lb-a
          role: haproxy
EOF
  fi

  if [ -n "${CLOUD_LB_B_HOST:-}" ]; then
    cat <<EOF
      - targets:
          - ${CLOUD_LB_B_HOST}:${CLOUD_LB_B_METRICS_PORT}
        labels:
          node: cloud-lb-b
          role: haproxy
EOF
  fi
}

render_minio_secondary_target() {
  if [ -n "${MINIO_SECONDARY_HOST:-}" ]; then
    cat <<EOF
      - targets:
          - ${MINIO_SECONDARY_API_SCRAPE_HOST}:${MINIO_SECONDARY_API_PORT}
        labels:
          node: minio-secondary
          role: minio
EOF
  fi
}

render_node_exporter_optional_targets() {
  if [ -n "${CLOUD_LB_A_HOST:-}" ]; then
    cat <<EOF
      - targets:
          - ${CLOUD_LB_A_HOST}:${CLOUD_LB_A_NODE_EXPORTER_PORT}
        labels:
          node: cloud-lb-a
          role: host
EOF
  fi

  if [ -n "${CLOUD_LB_B_HOST:-}" ]; then
    cat <<EOF
      - targets:
          - ${CLOUD_LB_B_HOST}:${CLOUD_LB_B_NODE_EXPORTER_PORT}
        labels:
          node: cloud-lb-b
          role: host
EOF
  fi

  if [ -n "${MINIO_SECONDARY_HOST:-}" ]; then
    cat <<EOF
      - targets:
          - ${MINIO_SECONDARY_NODE_EXPORTER_SCRAPE_HOST}:${MINIO_SECONDARY_NODE_EXPORTER_PORT}
        labels:
          node: minio-secondary
          role: host
EOF
  fi
}

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
      - targets:
          - ${CITY_A_HOST}:${CITY_A_ETCD_METRICS_PORT}
        labels:
          node: city-a
          role: etcd
      - targets:
          - ${CITY_B_HOST}:${CITY_B_ETCD_METRICS_PORT}
        labels:
          node: city-b
          role: etcd
      - targets:
          - ${CLOUD_CONTROL_ETCD_SCRAPE_HOST}:${CLOUD_CONTROL_ETCD_METRICS_PORT}
        labels:
          node: cloud-control
          role: etcd

  - job_name: postgres_exporter
    static_configs:
      - targets:
          - ${CITY_A_HOST}:${CITY_A_POSTGRES_EXPORTER_PORT}
        labels:
          node: city-a
          role: postgres
      - targets:
          - ${CITY_B_HOST}:${CITY_B_POSTGRES_EXPORTER_PORT}
        labels:
          node: city-b
          role: postgres

$(render_haproxy_job)
  - job_name: minio
    scheme: https
    metrics_path: /minio/v2/metrics/cluster
    tls_config:
      insecure_skip_verify: true
    static_configs:
      - targets:
          - ${MINIO_PRIMARY_API_SCRAPE_HOST}:${MINIO_PRIMARY_API_PORT}
        labels:
          node: minio-primary
          role: minio
$(render_minio_secondary_target)

  - job_name: node_exporter
    static_configs:
      - targets:
          - ${CITY_A_HOST}:${CITY_A_NODE_EXPORTER_PORT}
        labels:
          node: city-a
          role: host
      - targets:
          - ${CITY_B_HOST}:${CITY_B_NODE_EXPORTER_PORT}
        labels:
          node: city-b
          role: host
      - targets:
          - ${CLOUD_CONTROL_NODE_EXPORTER_SCRAPE_HOST}:${CLOUD_CONTROL_NODE_EXPORTER_PORT}
        labels:
          node: cloud-control
          role: host
$(render_node_exporter_optional_targets)
      - targets:
          - ${MINIO_PRIMARY_NODE_EXPORTER_SCRAPE_HOST}:${MINIO_PRIMARY_NODE_EXPORTER_PORT}
        labels:
          node: minio-primary
          role: host
EOF

exec /bin/prometheus \
  --config.file="${target}" \
  --web.enable-lifecycle \
  --storage.tsdb.path=/prometheus \
  --storage.tsdb.retention.time=3d \
  --web.console.libraries=/usr/share/prometheus/console_libraries \
  --web.console.templates=/usr/share/prometheus/consoles
