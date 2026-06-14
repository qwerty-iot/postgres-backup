#!/usr/bin/env bash
################################################
##    Copyright 2026, Jim Wert                ##
################################################

set -Eeuo pipefail

PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-postgres}"
RESTORE_SCOPE="${RESTORE_SCOPE:-database}"
WORKDIR="${WORKDIR:-/tmp/postgres-backup}"

export PGPORT PGDATABASE

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "missing required environment variable: ${name}" >&2
    exit 1
  fi
}

require_common_env() {
  require_env AZURE_CONTAINER
  require_env AZURE_CONNSTRING
  require_env BACKUP_PREFIX
  require_env PGHOST
  require_env PGUSER
}

normalize_backup_prefix() {
  BACKUP_PREFIX="${BACKUP_PREFIX%/}"
}

prepare_workdir() {
  mkdir -p "${WORKDIR}"
}

parse_databases() {
  require_env POSTGRES_DATABASES

  local normalized="${POSTGRES_DATABASES//,/ }"
  # shellcheck disable=SC2206
  POSTGRES_DATABASE_LIST=(${normalized})

  if [ "${#POSTGRES_DATABASE_LIST[@]}" -eq 0 ]; then
    echo "POSTGRES_DATABASES did not contain any database names" >&2
    exit 1
  fi
}

latest_blob() {
  local prefix="$1"
  local blob

  blob="$(az storage blob list \
    --container-name "${AZURE_CONTAINER}" \
    --connection-string="${AZURE_CONNSTRING}" \
    --prefix="${prefix}" \
    --query "sort_by([].name, &@)[-1]" \
    -o tsv)"

  if [ -z "${blob}" ] || [ "${blob}" = "None" ]; then
    echo "no backup found under prefix: ${prefix}" >&2
    exit 1
  fi

  printf '%s\n' "${blob}"
}

upload_blob() {
  local file="$1"
  local blob="$2"

  echo "uploading ${file} to ${blob}"
  az storage blob upload \
    --container-name "${AZURE_CONTAINER}" \
    --connection-string="${AZURE_CONNSTRING}" \
    --name="${blob}" \
    --file="${file}" \
    --overwrite true
}

download_blob() {
  local blob="$1"
  local file="$2"

  echo "downloading ${blob} to ${file}"
  az storage blob download \
    --no-progress \
    --container-name "${AZURE_CONTAINER}" \
    --connection-string="${AZURE_CONNSTRING}" \
    --name="${blob}" \
    --file="${file}" \
    --overwrite
}

backup_globals() {
  local timestamp="$1"
  local file="${WORKDIR}/globals-${timestamp}.sql.gz"
  local blob="${BACKUP_PREFIX}/globals/${timestamp}.sql.gz"

  echo "backing up postgres globals"
  pg_dumpall --globals-only --no-password --database="${PGDATABASE}" | gzip > "${file}"
  upload_blob "${file}" "${blob}"
}

backup_database() {
  local database="$1"
  local timestamp="$2"
  local file="${WORKDIR}/${database}-${timestamp}.dump"
  local blob="${BACKUP_PREFIX}/databases/${database}/${timestamp}.dump"

  echo "backing up database: ${database}"
  pg_dump --format=custom --blobs --verbose --no-password --dbname="${database}" --file="${file}"
  upload_blob "${file}" "${blob}"
}

backup_all() {
  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"

  parse_databases
  backup_globals "${timestamp}"

  local database
  for database in "${POSTGRES_DATABASE_LIST[@]}"; do
    backup_database "${database}" "${timestamp}"
  done
}

restore_globals() {
  local requested_blob="${1:-}"
  local blob="${requested_blob}"
  local file="${WORKDIR}/restore-globals.sql.gz"

  if [ -z "${blob}" ]; then
    blob="$(latest_blob "${BACKUP_PREFIX}/globals/")"
  fi

  download_blob "${blob}" "${file}"

  echo "restoring postgres globals from ${blob}"
  gzip -dc "${file}" | psql --no-psqlrc --no-password --dbname="${PGDATABASE}" --set=ON_ERROR_STOP=1
}

replace_database() {
  local database="$1"

  echo "dropping and recreating database: ${database}"
  psql --no-psqlrc --no-password --dbname="${PGDATABASE}" --set=ON_ERROR_STOP=1 --set=db="${database}" <<'SQL'
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'db'
  AND pid <> pg_backend_pid();

DROP DATABASE IF EXISTS :"db";
CREATE DATABASE :"db";
SQL
}

restore_database() {
  local database="$1"
  local requested_blob="${2:-}"
  local blob="${requested_blob}"
  local file="${WORKDIR}/restore-${database}.dump"

  if [ -z "${blob}" ]; then
    blob="$(latest_blob "${BACKUP_PREFIX}/databases/${database}/")"
  fi

  download_blob "${blob}" "${file}"
  replace_database "${database}"

  echo "restoring database ${database} from ${blob}"
  pg_restore --verbose --clean --if-exists --no-owner --exit-on-error --no-password --dbname="${database}" "${file}"
}

restore_all() {
  parse_databases
  restore_globals "${RESTORE_GLOBALS_NAME:-}"

  local database
  for database in "${POSTGRES_DATABASE_LIST[@]}"; do
    restore_database "${database}" ""
  done
}

restore_requested_scope() {
  case "${RESTORE_SCOPE}" in
    globals)
      restore_globals "${RESTORE_GLOBALS_NAME:-${RESTORE_NAME:-}}"
      ;;
    database)
      require_env RESTORE_DATABASE
      restore_database "${RESTORE_DATABASE}" "${RESTORE_NAME:-}"
      ;;
    all)
      restore_all
      ;;
    *)
      echo "invalid RESTORE_SCOPE: ${RESTORE_SCOPE}; expected database, globals, or all" >&2
      exit 1
      ;;
  esac
}

main() {
  require_common_env
  normalize_backup_prefix
  prepare_workdir

  if [ "${TASK:-}" = "restore" ]; then
    restore_requested_scope
  else
    backup_all
  fi
}

main "$@"
