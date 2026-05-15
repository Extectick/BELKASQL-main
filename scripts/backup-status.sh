#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

wait_for_cluster

primary="$(detect_primary)"
backup_node="$(detect_replica || true)"

if [[ -z "${backup_node}" ]]; then
  backup_node="${primary}"
fi

echo "Primary node: ${primary}"
echo "Backup node: ${backup_node}"
echo "Creating a full pgBackRest backup..."
if ! compose_exec "${backup_node}" pgbackrest --stanza="${PGBACKREST_STANZA}" --type=full backup; then
  if [[ "${backup_node}" != "${primary}" ]]; then
    echo "Replica-local backup path is unavailable in the current pgBackRest topology. Falling back to primary ${primary}."
    backup_node="${primary}"
    compose_exec "${backup_node}" pgbackrest --stanza="${PGBACKREST_STANZA}" --type=full backup
  else
    exit 1
  fi
fi

echo
echo "pgBackRest info:"
compose_exec "${backup_node}" pgbackrest --stanza="${PGBACKREST_STANZA}" info

echo
echo "Waiting for MinIO bucket replication to converge..."
for _ in $(seq 1 30); do
  if output="$(compose_exec_service minio-primary minio-admin sh -lc "mc --insecure ls secondary/${PGBACKREST_BUCKET} 2>/dev/null" 2>/dev/null)" && [[ -n "${output}" ]]; then
    break
  fi
  sleep 2
done

echo
echo "Primary bucket:"
compose_exec_service minio-primary minio-admin sh -lc "mc --insecure ls primary/${PGBACKREST_BUCKET}"

echo
echo "Secondary bucket:"
compose_exec_service minio-primary minio-admin sh -lc "mc --insecure ls secondary/${PGBACKREST_BUCKET}"

echo
echo "Replication rules:"
compose_exec_service minio-primary minio-admin sh -lc "mc --insecure replicate ls primary/${PGBACKREST_BUCKET}"
