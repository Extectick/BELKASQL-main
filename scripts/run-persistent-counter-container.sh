#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-belka/persistent-counter:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-persistent-counter-demo}"
PGHOST="${PGHOST:-10.77.0.100}"
PGPORT="${PGPORT:-5000}"
PGUSER="${PGUSER:-appuser}"
PGPASSWORD="${PGPASSWORD:-app-pass}"
PGDATABASE="${PGDATABASE:-appdb}"
COUNTER_NAME="${COUNTER_NAME:-global-counter}"
COUNTER_INTERVAL="${COUNTER_INTERVAL:-1.0}"
RESET_ON_START="${RESET_ON_START:-false}"

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

args=(
  docker run -d
  --name "${CONTAINER_NAME}"
  --restart unless-stopped
  -e PGHOST="${PGHOST}"
  -e PGPORT="${PGPORT}"
  -e PGUSER="${PGUSER}"
  -e PGPASSWORD="${PGPASSWORD}"
  -e PGDATABASE="${PGDATABASE}"
  "${IMAGE_NAME}"
  --interval "${COUNTER_INTERVAL}"
  --counter-name "${COUNTER_NAME}"
)

if [[ "${RESET_ON_START}" == "true" ]]; then
  args+=(--reset-on-start)
fi

"${args[@]}"
