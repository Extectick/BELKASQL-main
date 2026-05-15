#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./automation-common.sh
source "${SCRIPT_DIR}/automation-common.sh"

parse_args "$@"
load_env
prepare_compose

PUBLISHED_BIND_HOST="${INTERNAL_BIND_IP:-127.0.0.1}"

note "Running preflight before health check"
run_preflight

note "docker compose ps"
compose_role ps

case "${ROLE}" in
  db-node)
    note "Checking Patroni REST API"
    compose_role exec -T db bash -lc "curl -fs http://127.0.0.1:8008/patroni"

    note "Checking published Patroni REST port"
    curl -fsS "http://${PUBLISHED_BIND_HOST}:${PATRONI_API_PUBLISHED_PORT}/patroni" >/dev/null

    note "Checking Patroni cluster view"
    compose_role exec -T db bash -lc "patronictl -c /etc/patroni/patroni.yml list"

    note "Checking local PgBouncer socket"
    compose_role exec -T db bash -lc "</dev/tcp/127.0.0.1/6432"

    note "Checking published PgBouncer port"
    bash -lc "</dev/tcp/${PUBLISHED_BIND_HOST}/${PGBOUNCER_PUBLISHED_PORT}"

    note "Checking local HAProxy listener"
    compose_role exec -T local-lb sh -lc "haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null && if command -v ss >/dev/null 2>&1; then ss -lnt | grep -E '(:5000|:5001)'; elif command -v netstat >/dev/null 2>&1; then netstat -lnt | grep -E '(:5000|:5001)'; else echo 'HAProxy config valid; listener inspection tool is not installed in this image.'; fi"
    ;;
  control-node)
    note "Checking etcd endpoint health"
    compose_role exec -T etcd etcdctl --endpoints=http://127.0.0.1:2379 endpoint health
    ;;
  lb-node)
    note "Checking HAProxy configuration and listeners"
    compose_role exec -T lb sh -lc "haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null && if command -v ss >/dev/null 2>&1; then ss -lnt | grep -E '(:5000|:5001)'; elif command -v netstat >/dev/null 2>&1; then netstat -lnt | grep -E '(:5000|:5001)'; else echo 'HAProxy config valid; listener inspection tool is not installed in this image.'; fi"

    note "Checking Keepalived configuration"
    compose_role exec -T lb sh -lc "test -s /etc/keepalived/keepalived.conf && grep -E 'state|priority|virtual_ipaddress' /etc/keepalived/keepalived.conf"
    ;;
  storage-node)
    note "Checking MinIO liveness"
    compose_role exec -T minio sh -lc "curl -kfs https://127.0.0.1:9000/minio/health/live || curl -fs http://127.0.0.1:9000/minio/health/live"

    if [[ "${WITH_ADMIN}" -eq 1 ]]; then
      note "Checking replication rules via mc"
      compose_role exec -T minio-admin sh -lc "mc --insecure replicate ls primary/${PGBACKREST_S3_BUCKET} || true"
    fi
    ;;
  observability-node)
    note "Checking Prometheus readiness"
    curl -fsS "http://${PUBLISHED_BIND_HOST}:${PROMETHEUS_PUBLISHED_PORT}/-/ready" >/dev/null

    note "Checking Loki readiness"
    curl -fsS "http://${PUBLISHED_BIND_HOST}:${LOKI_PUBLISHED_PORT}/ready" >/dev/null

    note "Checking Alertmanager readiness"
    curl -fsS "http://${PUBLISHED_BIND_HOST}:${ALERTMANAGER_PUBLISHED_PORT}/-/ready" >/dev/null

    note "Checking Grafana health"
    curl -fsS "http://${PUBLISHED_BIND_HOST}:${GRAFANA_PUBLISHED_PORT}/api/health" | grep -q 'ok'
    ;;
esac

note "Health check completed"
