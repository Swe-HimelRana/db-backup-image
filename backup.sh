#!/usr/bin/env bash
set -euo pipefail

#####################################
# Logging helpers
#####################################
log() { printf '%s [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$1" "$2"; }
log_info()  { log INFO  "$*"; }
log_warn()  { log WARN  "$*"; }
log_error() { log ERROR "$*"; }

#####################################
# ===== Config via env =====
#####################################
: "${DB_TYPE:=}"                      # mysql|postgres|redis|mongodb
: "${DB_HOST:=localhost}"
: "${DB_PORT:=}"                      # default per DB if empty
: "${DB_USER:=}"
: "${DB_PASSWORD:=}"
: "${DB_NAME:=}"                      # ignored when dumping ALL; retained for compatibility
: "${MONGO_URI:=}"                    # if set, used for Mongo; dumps all DBs by default

: "${BACKUP_DIR:=/backup/output}"
: "${BACKUP_PREFIX:=backup}"          # used inside archive folder names
: "${BACKUP_NAME:=}"                  # filename "date-BACKUP_NAME.*" (default: DB_TYPE)
: "${COMPRESS:=gzip}"                 # gzip|none
: "${KEEP_LOCAL:=true}"               # true|false

# Optional: exclude DBs by regex (applies to MySQL/Postgres enumeration)
# Example: DBS_EXCLUDE="^(test|tmp_)"
: "${DBS_EXCLUDE:=}"

# Upload settings (pick one)
: "${RCLONE_REMOTE:=}"                # e.g. "pcloud:Backups/db", "s3:my-bucket/path"
: "${RCLONE_FLAGS:=--transfers 4 --checkers 8 --fast-list}"
: "${S3_URL:=}"                       # e.g. "s3://my-bucket/path/"
: "${S3CMD_OPTS:=}"

# Retention (remote) — works with rclone remotes (incl. pCloud).
# Deletes remote files older than N days in destination path.
: "${RETENTION_DAYS:=}"               # e.g. 15

#####################################
# Derived values
#####################################
[[ -n "${DB_TYPE}" ]] || { log_error "DB_TYPE is required (mysql|postgres|redis|mongodb)"; exit 2; }

# Date-first filename (local time by default)
date_prefix="$(date +%d-%m-%Y)"
artifact_basename="${date_prefix}-${BACKUP_NAME:-${DB_TYPE}}"

# Unique internal folder to avoid collisions
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive_dir="${BACKUP_PREFIX}-${DB_TYPE}-${timestamp}"

mkdir -p "${BACKUP_DIR}"

#####################################
# Cleanup + Retention (signal-safe)
#####################################
uploaded="false"
artifact=""         # set later
cleanup() {
  # don't let cleanup failures hide the real exit code
  set +e
  local exit_code=$?

  # Remote retention (pCloud or any rclone backend)
  if [[ -n "${RETENTION_DAYS}" && "${RETENTION_DAYS}" =~ ^[0-9]+$ && "${RETENTION_DAYS}" -gt 0 && -n "${RCLONE_REMOTE}" ]]; then
    log_info "Retention: removing files older than ${RETENTION_DAYS} days at ${RCLONE_REMOTE}"
    # Restrict to our naming pattern to be safe
    rclone delete "${RCLONE_REMOTE}" \
      --min-age "${RETENTION_DAYS}d" \
      --include "*-${BACKUP_NAME:-${DB_TYPE}}.tar" \
      --include "*-${BACKUP_NAME:-${DB_TYPE}}.tar.gz" \
      ${RCLONE_FLAGS}
    # Then clean up any empty directories
    rclone rmdirs "${RCLONE_REMOTE}" ${RCLONE_FLAGS}
    log_info "Retention: completed."
  elif [[ -n "${RETENTION_DAYS}" && -n "${S3_URL}" && -z "${RCLONE_REMOTE}" ]]; then
    log_warn "Retention requested but only S3_URL provided. Use an S3 lifecycle rule or switch to RCLONE_REMOTE for scripted pruning."
  fi

  # Remove local artifact if requested and upload succeeded
  if [[ -n "${artifact}" && "${uploaded}" == "true" && "${KEEP_LOCAL}" != "true" ]]; then
    log_info "Removing local artifact after upload: ${artifact}"
    rm -f "${artifact}" || log_warn "Failed to remove local artifact: ${artifact}"
  fi

  # Temp dir cleanup
  if [[ -n "${tmpdir:-}" && -d "${tmpdir:-}" ]]; then
    log_info "Cleaning up temp directory: ${tmpdir}"
    rm -rf "${tmpdir}" || log_warn "Failed to remove temp directory: ${tmpdir}"
  fi

  if [[ $exit_code -ne 0 ]]; then
    log_error "Backup terminated with exit code ${exit_code}"
  else
    log_info "Cleanup complete. Exiting successfully."
  fi
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM HUP

# Create tmp after trap so it always gets cleaned
tmpdir="$(mktemp -d)"
data_path="${tmpdir}/${archive_dir}"

#####################################
# Dump functions
#####################################
dump_mysql_all() {
  local host="${DB_HOST}" port="${DB_PORT:-3306}"
  local auth=()
  [[ -n "${DB_USER}" ]] && auth+=( -u "${DB_USER}" )
  [[ -n "${DB_PASSWORD}" ]] && export MYSQL_PWD="${DB_PASSWORD}"

  mkdir -p "${data_path}/mysql"
  log_info "Enumerating MySQL databases on ${host}:${port}"
  local exclude_re="^(information_schema|performance_schema|sys)$"
  [[ -n "${DBS_EXCLUDE}" ]] && exclude_re="(${exclude_re}|${DBS_EXCLUDE})"

  mapfile -t dbs < <(mysql -h "${host}" -P "${port}" "${auth[@]}" -N -e 'SHOW DATABASES;' \
                      | grep -Ev "${exclude_re}" || true)

  if [[ ${#dbs[@]} -eq 0 ]]; then
    log_warn "No MySQL databases to dump after exclusions."
  fi

  for db in "${dbs[@]}"; do
    log_info "Dumping MySQL DB: ${db}"
    mysqldump -h "${host}" -P "${port}" "${auth[@]}" \
      --single-transaction --routines --triggers --events --hex-blob \
      "${db}" > "${data_path}/mysql/${db}.sql"
  done

  log_info "Dumping MySQL system DB: mysql (users/privileges)"
  mysqldump -h "${host}" -P "${port}" "${auth[@]}" \
    --single-transaction --routines --triggers --events --hex-blob \
    mysql > "${data_path}/mysql/mysql.sql"
}

dump_postgres_all() {
  local host="${DB_HOST}" port="${DB_PORT:-5432}"
  export PGPASSWORD="${DB_PASSWORD:-}"
  local user="${DB_USER:-postgres}"

  mkdir -p "${data_path}/postgres"
  log_info "Enumerating PostgreSQL databases on ${host}:${port} as ${user}"
  mapfile -t dbs < <(psql -h "${host}" -p "${port}" -U "${user}" -t -A -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');" \
    | sed '/^\s*$/d' || true)

  if [[ -n "${DBS_EXCLUDE}" ]]; then
    mapfile -t dbs < <(printf "%s\n" "${dbs[@]}" | grep -Ev "${DBS_EXCLUDE}" || true)
  fi

  log_info "Dumping PostgreSQL globals (roles, etc.)"
  pg_dumpall -h "${host}" -p "${port}" -U "${user}" -g > "${data_path}/postgres/globals.sql"

  if [[ ${#dbs[@]} -eq 0 ]]; then
    log_warn "No PostgreSQL databases to dump after exclusions."
  fi

  for db in "${dbs[@]}"; do
    log_info "Dumping PostgreSQL DB: ${db}"
    pg_dump -h "${host}" -p "${port}" -U "${user}" -F c -d "${db}" -f "${data_path}/postgres/${db}.pgdump"
  done
}

dump_redis_all() {
  local host="${DB_HOST}" port="${DB_PORT:-6379}"
  mkdir -p "${data_path}/redis"}
  log_info "Dumping Redis RDB snapshot from ${host}:${port}"
  if [[ -n "${DB_PASSWORD}" ]]; then
    redis-cli -h "${host}" -p "${port}" -a "${DB_PASSWORD}" --rdb "${data_path}/redis/dump.rdb"
  else
    redis-cli -h "${host}" -p "${port}" --rdb "${data_path}/redis/dump.rdb"
  fi
}

dump_mongo_all() {
  mkdir -p "${data_path}/mongodb"
  if [[ -n "${MONGO_URI}" ]]; then
    log_info "Dumping MongoDB (all DBs) via URI"
    mongodump --uri="${MONGO_URI}" --out "${data_path}/mongodb"
  else
    local host="${DB_HOST}" port="${DB_PORT:-27017}"
    local args=( --host "${host}" --port "${port}" )
    [[ -n "${DB_USER}" ]] && args+=( --username "${DB_USER}" )
    [[ -n "${DB_PASSWORD}" ]] && args+=( --password "${DB_PASSWORD}" )
    log_info "Dumping MongoDB (all DBs) from ${host}:${port}"
    mongodump "${args[@]}" --out "${data_path}/mongodb"
  fi
}

#####################################
# Run
#####################################
log_info "Starting ${DB_TYPE} backup (all databases) at ${timestamp}"
mkdir -p "${data_path}"

case "${DB_TYPE}" in
  mysql)    dump_mysql_all ;;
  postgres) dump_postgres_all ;;
  redis)    dump_redis_all ;;
  mongodb)  dump_mongo_all ;;
  *)        log_error "DB_TYPE must be one of: mysql|postgres|redis|mongodb"; exit 2 ;;
esac

#####################################
# Package + compress
#####################################
artifact="${BACKUP_DIR}/${artifact_basename}.tar"
log_info "Packaging archive: ${artifact}"
tar -cf "${artifact}" -C "${tmpdir}" "${archive_dir}"

if [[ "${COMPRESS}" == "gzip" ]]; then
  log_info "Compressing with gzip"
  gzip -9 "${artifact}"
  artifact="${artifact}.gz"
fi

log_info "Artifact ready: ${artifact}"

#####################################
# Upload
#####################################
if [[ -n "${RCLONE_REMOTE}" ]]; then
  log_info "Uploading with rclone to ${RCLONE_REMOTE}"
  rclone copy "${artifact}" "${RCLONE_REMOTE}" ${RCLONE_FLAGS} --progress
  uploaded="true"
elif [[ -n "${S3_URL}" ]]; then
  log_info "Uploading with s3cmd to ${S3_URL}"
  s3cmd put ${S3CMD_OPTS} "${artifact}" "${S3_URL}"
  uploaded="true"
else
  log_warn "No remote configured (RCLONE_REMOTE or S3_URL). Skipping upload."
fi

log_info "Backup complete."
