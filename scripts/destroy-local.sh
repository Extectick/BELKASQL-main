#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

for node in cloud-lb-b cloud-lb-a city-b city-a minio-primary minio-secondary cloud-control cloud-observability; do
  compose_down_node "${node}" >/dev/null 2>&1 || true
done

echo "Local deployment removed."
