#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REMOVE_DOCKER=0
REMOVE_VOLUMES=0
ASSUME_YES=0

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

usage() {
  cat <<'EOF'
Usage:
  bash ./cleanup-db-ingress.sh [--docker-local] [--volumes] [--yes]

What it removes by default:
  - docs/generated/*
  - *.bak-* files created by bootstrap-db-ingress.sh
  - sum_demo_*.log files in the repo root

Optional:
  --docker-local  Stop and remove the local BELKASQL lab containers
  --volumes       Also remove local BELKASQL Docker volumes (implies --docker-local)
  --yes           Do not prompt before deleting files / containers
EOF
}

confirm() {
  local prompt="$1"
  local answer=""

  if [[ "${ASSUME_YES}" -eq 1 ]]; then
    return 0
  fi

  while true; do
    read -r -p "${prompt} [y/N]: " answer
    case "${answer}" in
      y|Y|yes|YES)
        return 0
        ;;
      n|N|no|NO|'')
        return 1
        ;;
      *)
        warn "please answer y or n"
        ;;
    esac
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --docker-local)
        REMOVE_DOCKER=1
        ;;
      --volumes)
        REMOVE_DOCKER=1
        REMOVE_VOLUMES=1
        ;;
      --yes)
        ASSUME_YES=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done
}

remove_generated_files() {
  local deleted_any=0

  if [[ -d "${PROJECT_ROOT}/docs/generated" ]]; then
    if confirm "Remove generated secret summaries from docs/generated?"; then
      find "${PROJECT_ROOT}/docs/generated" -type f -delete
      deleted_any=1
      note "Removed generated files from docs/generated"
    fi
  fi

  if find "${PROJECT_ROOT}" -type f -name '*.bak-*' | grep -q .; then
    if confirm "Remove bootstrap backup files (*.bak-*)?"; then
      find "${PROJECT_ROOT}" -type f -name '*.bak-*' -delete
      deleted_any=1
      note "Removed bootstrap backup files"
    fi
  fi

  if find "${PROJECT_ROOT}" -maxdepth 1 -type f -name 'sum_demo_*.log' | grep -q .; then
    if confirm "Remove local sum_demo log files?"; then
      find "${PROJECT_ROOT}" -maxdepth 1 -type f -name 'sum_demo_*.log' -delete
      deleted_any=1
      note "Removed local sum_demo log files"
    fi
  fi

  if [[ "${deleted_any}" -eq 0 ]]; then
    note "No generated files needed cleanup"
  fi
}

compose_down() {
  local env_file="$1"
  local compose_file="$2"
  shift 2

  local args=("$@")

  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not found, skipping local lab cleanup"
    return 0
  fi

  (
    cd "${PROJECT_ROOT}"
    if [[ "${REMOVE_VOLUMES}" -eq 1 ]]; then
      docker compose "${args[@]}" --env-file "${env_file}" -f "${compose_file}" down --volumes
    else
      docker compose "${args[@]}" --env-file "${env_file}" -f "${compose_file}" down
    fi
  ) || true
}

cleanup_local_lab() {
  if ! confirm "Stop and remove the local BELKASQL Docker lab on this host?"; then
    return 0
  fi

  note "Stopping local BELKASQL lab"
  compose_down "observability-node/env/cloud-observability.env" "observability-node/docker-compose.yml"
  compose_down "control-node/env/cloud-control.env" "control-node/docker-compose.yml"
  compose_down "storage-node/env/minio-primary.env" "storage-node/docker-compose.yml" --profile admin
  compose_down "storage-node/env/minio-secondary.env" "storage-node/docker-compose.yml"
  compose_down "db-node/env/city-a.env" "db-node/docker-compose.yml"
  compose_down "db-node/env/city-b.env" "db-node/docker-compose.yml"
  compose_down "lb-node/env/cloud-lb-a.env" "lb-node/docker-compose.yml"
  compose_down "lb-node/env/cloud-lb-b.env" "lb-node/docker-compose.yml"

  if [[ "${REMOVE_VOLUMES}" -eq 1 ]] && command -v docker >/dev/null 2>&1; then
    if docker network inspect belkasql_belka-net >/dev/null 2>&1; then
      docker network rm belkasql_belka-net >/dev/null 2>&1 || true
      note "Tried to remove belkasql_belka-net"
    fi
  fi
}

main() {
  parse_args "$@"
  remove_generated_files

  if [[ "${REMOVE_DOCKER}" -eq 1 ]]; then
    cleanup_local_lab
  fi
}

main "$@"
