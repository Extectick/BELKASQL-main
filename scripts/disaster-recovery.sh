#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

wait_for_cluster

primary="$(detect_primary)"
backup_node="$(detect_replica || true)"
restore_tester="city-b"

if [[ -z "${backup_node}" ]]; then
  backup_node="${primary}"
fi

echo "Primary node: ${primary}"
echo "Backup node: ${backup_node}"
echo "Ensuring an up-to-date full backup exists before DR validation..."
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
echo "Current replication configuration:"
compose_exec_service minio-primary minio-admin sh -lc "mc --insecure replicate ls primary/${PGBACKREST_BUCKET}"

echo
echo "Stopping minio-primary to simulate the loss of the main backup region..."
compose_stop_node minio-primary

cleanup() {
  compose_start_node minio-primary >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo
echo "Checking pgBackRest metadata against the replicated secondary bucket..."
compose_exec "${restore_tester}" bash -lc "export PGBACKREST_REPO1_S3_ENDPOINT='${MINIO_SECONDARY_ENDPOINT}'; export PGBACKREST_REPO1_S3_KEY='${MINIO_SECONDARY_ROOT_USER}'; export PGBACKREST_REPO1_S3_KEY_SECRET='${MINIO_SECONDARY_ROOT_PASSWORD}'; pgbackrest --stanza='${PGBACKREST_STANZA}' info"

echo
echo "Running a scratch restore from the secondary region into /tmp/dr-restore..."
compose_exec "${restore_tester}" bash -lc "rm -rf /tmp/dr-restore && mkdir -p /tmp/dr-restore && export PGBACKREST_REPO1_S3_ENDPOINT='${MINIO_SECONDARY_ENDPOINT}' && export PGBACKREST_REPO1_S3_KEY='${MINIO_SECONDARY_ROOT_USER}' && export PGBACKREST_REPO1_S3_KEY_SECRET='${MINIO_SECONDARY_ROOT_PASSWORD}' && pgbackrest --stanza='${PGBACKREST_STANZA}' --pg1-path=/tmp/dr-restore restore && ls -1 /tmp/dr-restore | head"

echo
echo "Disaster recovery validation completed. minio-primary will be started again on exit."
