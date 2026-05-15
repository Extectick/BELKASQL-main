#!/bin/sh
set -eu

until mc --insecure alias set primary "https://${MINIO_PRIMARY_HOST}:9000" "${MINIO_PRIMARY_ROOT_USER}" "${MINIO_PRIMARY_ROOT_PASSWORD}" >/dev/null 2>&1; do
  sleep 2
done

until mc --insecure alias set secondary "https://${MINIO_SECONDARY_HOST}:9000" "${MINIO_SECONDARY_ROOT_USER}" "${MINIO_SECONDARY_ROOT_PASSWORD}" >/dev/null 2>&1; do
  sleep 2
done

mc --insecure mirror --overwrite --remove --watch "primary/${PGBACKREST_S3_BUCKET}" "secondary/${PGBACKREST_S3_BUCKET}"
