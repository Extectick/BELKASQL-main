#!/usr/bin/env bash
set -euo pipefail

TAG="belka-internal-service-ip"
CONFIG_FILE="${CONFIG_FILE:-/etc/belkasql/internal-service-ip.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

SERVICE_IP="${SERVICE_IP:-10.77.0.100}"
SERVICE_CIDR="${SERVICE_CIDR:-32}"
SERVICE_IFACE="${SERVICE_IFACE:-lo}"
ROUTE_IFACE="${ROUTE_IFACE:-wg0}"
LOCAL_NODE_NAME="${LOCAL_NODE_NAME:-}"
LOCAL_NODE_IP="${LOCAL_NODE_IP:-}"
PRIMARY_NODE_NAME="${PRIMARY_NODE_NAME:-city-a-db}"
PRIMARY_NODE_IP="${PRIMARY_NODE_IP:-10.77.0.11}"
PRIMARY_NODE_API="${PRIMARY_NODE_API:-10.77.0.11}"
PRIMARY_PEER_KEY="${PRIMARY_PEER_KEY:-}"
SECONDARY_NODE_NAME="${SECONDARY_NODE_NAME:-city-b-db}"
SECONDARY_NODE_IP="${SECONDARY_NODE_IP:-10.77.0.12}"
SECONDARY_NODE_API="${SECONDARY_NODE_API:-10.77.0.12}"
SECONDARY_PEER_KEY="${SECONDARY_PEER_KEY:-}"

log() {
  local message="$1"
  logger -t "${TAG}" -- "${message}" || true
  echo "${message}"
}

fetch_cluster() {
  local endpoint
  for endpoint in "${PRIMARY_NODE_API}" "${SECONDARY_NODE_API}"; do
    if curl -fsS --max-time 4 "http://${endpoint}:8008/cluster" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

ensure_service_ip_absent() {
  if ip -4 addr show dev "${SERVICE_IFACE}" | grep -q " ${SERVICE_IP}/${SERVICE_CIDR}"; then
    ip addr del "${SERVICE_IP}/${SERVICE_CIDR}" dev "${SERVICE_IFACE}"
    log "removed ${SERVICE_IP}/${SERVICE_CIDR} from ${SERVICE_IFACE}"
  fi
}

ensure_service_ip_present() {
  if ! ip -4 addr show dev "${SERVICE_IFACE}" | grep -q " ${SERVICE_IP}/${SERVICE_CIDR}"; then
    ip addr add "${SERVICE_IP}/${SERVICE_CIDR}" dev "${SERVICE_IFACE}"
    log "added ${SERVICE_IP}/${SERVICE_CIDR} to ${SERVICE_IFACE}"
  fi
}

delete_route_if_present() {
  if ip route show "${SERVICE_IP}/32" | grep -q "${SERVICE_IP}/32"; then
    ip route del "${SERVICE_IP}/32" 2>/dev/null || true
    log "removed routed path for ${SERVICE_IP}/32"
  fi
}

set_peer_allowed_ips() {
  local peer_key="$1"
  local node_ip="$2"
  local include_vip="$3"
  local allowed_ips="${node_ip}/32"

  [[ -n "${peer_key}" ]] || return 0

  if [[ "${include_vip}" == "yes" ]]; then
    allowed_ips="${allowed_ips},${SERVICE_IP}/32"
  fi

  wg set "${ROUTE_IFACE}" peer "${peer_key}" allowed-ips "${allowed_ips}"
}

reconcile_wireguard_peers() {
  local leader_name="$1"

  if [[ "${leader_name}" == "${PRIMARY_NODE_NAME}" ]]; then
    set_peer_allowed_ips "${PRIMARY_PEER_KEY}" "${PRIMARY_NODE_IP}" "yes"
    set_peer_allowed_ips "${SECONDARY_PEER_KEY}" "${SECONDARY_NODE_IP}" "no"
  elif [[ "${leader_name}" == "${SECONDARY_NODE_NAME}" ]]; then
    set_peer_allowed_ips "${PRIMARY_PEER_KEY}" "${PRIMARY_NODE_IP}" "no"
    set_peer_allowed_ips "${SECONDARY_PEER_KEY}" "${SECONDARY_NODE_IP}" "yes"
  else
    set_peer_allowed_ips "${PRIMARY_PEER_KEY}" "${PRIMARY_NODE_IP}" "no"
    set_peer_allowed_ips "${SECONDARY_PEER_KEY}" "${SECONDARY_NODE_IP}" "no"
  fi
}

ensure_route_to_vip() {
  local route_line
  route_line="$(ip route show "${SERVICE_IP}/32" 2>/dev/null || true)"

  if [[ "${route_line}" == "${SERVICE_IP}/32 dev ${ROUTE_IFACE}"* ]]; then
    return 0
  fi

  ip route replace "${SERVICE_IP}/32" dev "${ROUTE_IFACE}"
  log "routed ${SERVICE_IP}/32 via ${ROUTE_IFACE}"
}

cluster_json="$(fetch_cluster || true)"
if [[ -z "${cluster_json}" ]]; then
  log "cluster API unavailable; leaving current VIP state unchanged"
  exit 0
fi

leader_name="$(jq -r '.members[] | select(.role == "leader") | .name' <<<"${cluster_json}")"
leader_ip="$(jq -r '.members[] | select(.role == "leader") | .host' <<<"${cluster_json}")"

if [[ -z "${leader_name}" || -z "${leader_ip}" || "${leader_name}" == "null" || "${leader_ip}" == "null" ]]; then
  log "could not determine current leader from cluster API"
  exit 0
fi

reconcile_wireguard_peers "${leader_name}"

if [[ -n "${LOCAL_NODE_NAME}" && "${LOCAL_NODE_NAME}" == "${leader_name}" ]]; then
  delete_route_if_present
  ensure_service_ip_present
  exit 0
fi

ensure_service_ip_absent
ensure_route_to_vip
