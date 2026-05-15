#!/bin/sh
set -eu

until mc --insecure alias set primary "https://${MINIO_PRIMARY_HOST}:9000" "${MINIO_PRIMARY_ROOT_USER}" "${MINIO_PRIMARY_ROOT_PASSWORD}" >/dev/null 2>&1; do
  sleep 2
done

until mc --insecure alias set secondary "https://${MINIO_SECONDARY_HOST}:9000" "${MINIO_SECONDARY_ROOT_USER}" "${MINIO_SECONDARY_ROOT_PASSWORD}" >/dev/null 2>&1; do
  sleep 2
done

mc --insecure mb --ignore-existing "primary/${PGBACKREST_S3_BUCKET}" >/dev/null 2>&1 || true
mc --insecure mb --ignore-existing "secondary/${PGBACKREST_S3_BUCKET}" >/dev/null 2>&1 || true
mc --insecure version enable "primary/${PGBACKREST_S3_BUCKET}" >/dev/null 2>&1 || true
mc --insecure version enable "secondary/${PGBACKREST_S3_BUCKET}" >/dev/null 2>&1 || true

replication_rules="$(mc --insecure replicate ls "primary/${PGBACKREST_S3_BUCKET}" 2>/dev/null || true)"

case "${replication_rules}" in
  *"${MINIO_SECONDARY_HOST}:9000/${PGBACKREST_S3_BUCKET}"*)
    ;;
  *)
    mc --insecure replicate add "primary/${PGBACKREST_S3_BUCKET}" \
      --remote-bucket "https://${MINIO_SECONDARY_ROOT_USER}:${MINIO_SECONDARY_ROOT_PASSWORD}@${MINIO_SECONDARY_HOST}:9000/${PGBACKREST_S3_BUCKET}" \
    --replicate "delete,delete-marker,existing-objects" >/dev/null
    ;;
esac

mc --insecure replicate ls "primary/${PGBACKREST_S3_BUCKET}"
