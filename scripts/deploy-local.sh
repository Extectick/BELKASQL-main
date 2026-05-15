#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

echo "Creating shared Docker network if needed..."
ensure_network

echo "Deploying observability stack..."
compose_up_node cloud-observability

echo "Deploying control plane..."
compose_up_node cloud-control

echo "Deploying storage nodes..."
compose_up_node minio-secondary
compose_up_node minio-primary

echo "Deploying database nodes..."
compose_up_node city-a
compose_up_node city-b

echo "Deploying load balancers..."
compose_up_node cloud-lb-a
compose_up_node cloud-lb-b

echo
echo "Waiting for Patroni cluster..."
wait_for_cluster 300

echo
echo "Local deployment completed."
