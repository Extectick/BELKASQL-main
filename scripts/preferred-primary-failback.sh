#!/usr/bin/env bash
set -euo pipefail

TAG="belka-preferred-primary"
CONFIG_FILE="${CONFIG_FILE:-/etc/belkasql/preferred-primary.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

PREFERRED_NAME="${PREFERRED_NAME:-city-a-db}"
PREFERRED_API_HOST="${PREFERRED_API_HOST:-10.77.0.11}"
FALLBACK_NAME="${FALLBACK_NAME:-city-b-db}"
FALLBACK_API_HOST="${FALLBACK_API_HOST:-10.77.0.12}"
CLUSTER_NAME="${CLUSTER_NAME:-belka-ha}"
PATRONICTL_CONFIG="${PATRONICTL_CONFIG:-/etc/belkasql/patronictl.yml}"

log() {
  local message="$1"
  logger -t "${TAG}" -- "${message}" || true
  echo "${message}"
}

fetch_url() {
  local url="$1"
  curl -fsS --max-time 4 "${url}"
}

cluster_json=""
for api_host in "${PREFERRED_API_HOST}" "${FALLBACK_API_HOST}"; do
  if cluster_json="$(fetch_url "http://${api_host}:8008/cluster" 2>/dev/null)"; then
    break
  fi
done

if [[ -z "${cluster_json}" ]]; then
  log "cluster API is unavailable on both DB nodes"
  exit 0
fi

leader_name="$(jq -r '.members[] | select(.role == "leader") | .name' <<<"${cluster_json}")"
preferred_state="$(jq -r --arg name "${PREFERRED_NAME}" '.members[] | select(.name == $name) | .state // empty' <<<"${cluster_json}")"
preferred_role="$(jq -r --arg name "${PREFERRED_NAME}" '.members[] | select(.name == $name) | .role // empty' <<<"${cluster_json}")"
preferred_lag="$(jq -r --arg name "${PREFERRED_NAME}" '.members[] | select(.name == $name) | .lag // .receive_lag // -1' <<<"${cluster_json}")"

if [[ "${leader_name}" == "${PREFERRED_NAME}" ]]; then
  exit 0
fi

if [[ -z "${preferred_state}" || -z "${preferred_role}" ]]; then
  log "preferred node ${PREFERRED_NAME} is not present in cluster view"
  exit 0
fi

if [[ "${preferred_state}" != "running" && "${preferred_state}" != "streaming" ]]; then
  log "preferred node ${PREFERRED_NAME} is not ready yet: state=${preferred_state}"
  exit 0
fi

if [[ "${preferred_role}" != "replica" && "${preferred_role}" != "sync_standby" && "${preferred_role}" != "quorum_standby" ]]; then
  log "preferred node ${PREFERRED_NAME} has unsupported role=${preferred_role} for failback"
  exit 0
fi

if [[ "${preferred_lag}" != "0" ]]; then
  log "preferred node ${PREFERRED_NAME} is still lagging: lag=${preferred_lag}"
  exit 0
fi

log "requesting switchover from ${leader_name} to ${PREFERRED_NAME}"
if ! timeout 30 patronictl -c "${PATRONICTL_CONFIG}" switchover "${CLUSTER_NAME}" --leader "${leader_name}" --candidate "${PREFERRED_NAME}" --force >/tmp/belka-preferred-primary.last 2>&1; then
  log "switchover command returned non-zero; verifying cluster state"
fi

sleep 8

cluster_after=""
for api_host in "${PREFERRED_API_HOST}" "${FALLBACK_API_HOST}"; do
  if cluster_after="$(fetch_url "http://${api_host}:8008/cluster" 2>/dev/null)"; then
    break
  fi
done

if [[ -z "${cluster_after}" ]]; then
  log "cluster API became unavailable after switchover request"
  exit 1
fi

leader_after="$(jq -r '.members[] | select(.role == "leader") | .name' <<<"${cluster_after}")"
if [[ "${leader_after}" == "${PREFERRED_NAME}" ]]; then
  log "preferred node ${PREFERRED_NAME} is leader again"
  exit 0
fi

log "failback request finished but leader is still ${leader_after}"
exit 1
