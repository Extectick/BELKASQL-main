#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-belka/persistent-counter:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-persistent-counter-demo}"
PGHOST="${PGHOST:-10.77.0.100}"
PGPORT="${PGPORT:-5000}"
PGUSER="${PGUSER:-appuser}"
PGDATABASE="${PGDATABASE:-appdb}"
COUNTER_NAME="${COUNTER_NAME:-vip-test-counter}"
COUNTER_INTERVAL="${COUNTER_INTERVAL:-1.0}"
FOLLOW_LOGS="${FOLLOW_LOGS:-true}"

db_container="$(
  docker ps --format '{{.Names}}' |
    grep -E '^city-[ab]-db$' |
    head -n 1
)"

if [[ -z "${db_container}" ]]; then
  echo "No city-a-db/city-b-db container is running on this host" >&2
  exit 1
fi

app_password="$(
  docker inspect "${db_container}" --format '{{range .Config.Env}}{{println .}}{{end}}' |
    awk -F= '$1 == "APP_USER_PASSWORD" {print $2; exit}'
)"

if [[ -z "${app_password}" ]]; then
  echo "APP_USER_PASSWORD was not found in ${db_container}" >&2
  exit 1
fi

docker build -f test/Dockerfile.persistent-counter -t "${IMAGE_NAME}" .

PGHOST="${PGHOST}" \
PGPORT="${PGPORT}" \
PGUSER="${PGUSER}" \
PGPASSWORD="${app_password}" \
PGDATABASE="${PGDATABASE}" \
COUNTER_NAME="${COUNTER_NAME}" \
COUNTER_INTERVAL="${COUNTER_INTERVAL}" \
IMAGE_NAME="${IMAGE_NAME}" \
CONTAINER_NAME="${CONTAINER_NAME}" \
./scripts/run-persistent-counter-container.sh

if [[ "${FOLLOW_LOGS}" == "true" ]]; then
  docker logs -f "${CONTAINER_NAME}"
fi
