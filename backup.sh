#!/usr/bin/env bash
set -euo pipefail

# ===== Config via env =====
: "${DB_TYPE:=}"                      # mysql|postgres|redis|mongodb
: "${DB_HOST:=localhost}"
: "${DB_PORT:=}"                      # default per DB if empty
: "${DB_USER:=}"
: "${DB_PASSWORD:=}"
: "${DB_NAME:=}"                      # ignored when dumping ALL; retained for compatibility
: "${MONGO_URI:=}"                    # if set, used for Mongo; dumps all DBs by default

: "${BACKUP_DIR:=/backup/output}"
: "${BACKUP_PREFIX:=backup}"
: "${COMPRESS:=gzip}"                 # gzip|none
: "${KEEP_LOCAL:=true}"               # true|false

# Optional: exclude DBs by regex (applies to MySQL/Postgres enumeration)
# Example: DBS_EXCLUDE="^(test|tmp_)"
: "${DBS_EXCLUDE:=}"

# Upload settings (pick one)
: "${RCLONE_REMOTE:=}"                # e.g. "s3:my-bucket/path" or "gdrive:folder"
: "${RCLONE_FLAGS:=--transfers 4 --checkers 8 --fast-list}"
: "${S3_URL:=}"                       # e.g. "s3://my-bucket/path/"
: "${S3CMD_OPTS:=}"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${BACKUP_DIR}"

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

archive_base="${BACKUP_PREFIX}-${DB_TYPE:-unknown}-${timestamp}"
data_path="${tmpdir}/${archive_base}"

# -------- MySQL / MariaDB: dump all DBs (per-DB files) ----------
dump_mysql_all() {
  local host="${DB_HOST}" port="${DB_PORT:-3306}"
  local auth=()
  [[ -n "${DB_USER}" ]] && auth+=( -u "${DB_USER}" )
  [[ -n "${DB_PASSWORD}" ]] && export MYSQL_PWD="${DB_PASSWORD}"

  mkdir -p "${data_path}/mysql"
  echo "Enumerating MySQL databases..."
  # Default exclusions: info/perf/sys schemas (You can re-include by changing this pipeline)
  local exclude_re="^(information_schema|performance_schema|sys)$"
  [[ -n "${DBS_EXCLUDE}" ]] && exclude_re="(${exclude_re}|${DBS_EXCLUDE})"

  mapfile -t dbs < <(mysql -h "${host}" -P "${port}" "${auth[@]}" -N -e 'SHOW DATABASES;' \
                      | grep -Ev "${exclude_re}" || true)

  if [[ ${#dbs[@]} -eq 0 ]]; then
    echo "No MySQL databases to dump after exclusions."
  fi

  for db in "${dbs[@]}"; do
    echo "  -> Dumping MySQL DB: ${db}"
    mysqldump -h "${host}" -P "${port}" "${auth[@]}" \
      --single-transaction --routines --triggers --events --hex-blob \
      "${db}" > "${data_path}/mysql/${db}.sql"
  done

  # Also keep users/privileges from mysql system DB (highly recommended)
  echo "  -> Dumping MySQL system DB: mysql (users/privileges)"
  mysqldump -h "${host}" -P "${port}" "${auth[@]}" \
    --single-transaction --routines --triggers --events --hex-blob \
    mysql > "${data_path}/mysql/mysql.sql"
}

# -------- PostgreSQL: dump globals + each DB (custom format) ----------
dump_postgres_all() {
  local host="${DB_HOST}" port="${DB_PORT:-5432}"
  export PGPASSWORD="${DB_PASSWORD:-}"
  local user="${DB_USER:-postgres}"

  mkdir -p "${data_path}/postgres"
  echo "Enumerating PostgreSQL databases..."
  mapfile -t dbs < <(psql -h "${host}" -p "${port}" -U "${user}" -t -A -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');" \
    | sed '/^\s*$/d' || true)

  # Apply exclusions if provided
  if [[ -n "${DBS_EXCLUDE}" ]]; then
    mapfile -t dbs < <(printf "%s\n" "${dbs[@]}" | grep -Ev "${DBS_EXCLUDE}" || true)
  fi

  echo "  -> Dumping PostgreSQL globals (roles, etc.)"
  pg_dumpall -h "${host}" -p "${port}" -U "${user}" -g > "${data_path}/postgres/globals.sql"

  if [[ ${#dbs[@]} -eq 0 ]]; then
    echo "No PostgreSQL databases to dump after exclusions."
  fi

  for db in "${dbs[@]}"; do
    echo "  -> Dumping PostgreSQL DB: ${db}"
    pg_dump -h "${host}" -p "${port}" -U "${user}" -F c -d "${db}" -f "${data_path}/postgres/${db}.pgdump"
  done
}

# -------- Redis: RDB snapshot ----------
dump_redis_all() {
  local host="${DB_HOST}" port="${DB_PORT:-6379}"
  mkdir -p "${data_path}/redis"
  echo "  -> Dumping Redis RDB snapshot"
  if [[ -n "${DB_PASSWORD}" ]]; then
    redis-cli -h "${host}" -p "${port}" -a "${DB_PASSWORD}" --rdb "${data_path}/redis/dump.rdb"
  else
    redis-cli -h "${host}" -p "${port}" --rdb "${data_path}/redis/dump.rdb"
  fi
}

# -------- MongoDB: dump all DBs ----------
dump_mongo_all() {
  mkdir -p "${data_path}/mongodb"
  echo "  -> Dumping MongoDB (all databases)"
  if [[ -n "${MONGO_URI}" ]]; then
    mongodump --uri="${MONGO_URI}" --out "${data_path}/mongodb"
  else
    local host="${DB_HOST}" port="${DB_PORT:-27017}"
    local args=( --host "${host}" --port "${port}" )
    [[ -n "${DB_USER}" ]] && args+=( --username "${DB_USER}" )
    [[ -n "${DB_PASSWORD}" ]] && args+=( --password "${DB_PASSWORD}" )
    mongodump "${args[@]}" --out "${data_path}/mongodb"
  fi
}

echo "==> Starting ${DB_TYPE} backup (all databases) at ${timestamp}"
mkdir -p "${data_path}"

case "${DB_TYPE}" in
  mysql)    dump_mysql_all ;;
  postgres) dump_postgres_all ;;
  redis)    dump_redis_all ;;
  mongodb)  dump_mongo_all ;;
  *)
    echo "ERROR: set DB_TYPE to one of: mysql|postgres|redis|mongodb"
    exit 2
    ;;
esac

# Package + compress
artifact="${BACKUP_DIR}/${archive_base}.tar"
tar -cf "${artifact}" -C "${tmpdir}" "${archive_base}"

if [[ "${COMPRESS}" == "gzip" ]]; then
  gzip -9 "${artifact}"
  artifact="${artifact}.gz"
fi

echo "==> Artifact ready: ${artifact}"

# Upload
uploaded="false"
if [[ -n "${RCLONE_REMOTE}" ]]; then
  echo "==> Uploading with rclone to ${RCLONE_REMOTE}"
  rclone copy "${artifact}" "${RCLONE_REMOTE}" ${RCLONE_FLAGS} --progress
  uploaded="true"
elif [[ -n "${S3_URL}" ]]; then
  echo "==> Uploading with s3cmd to ${S3_URL}"
  s3cmd put ${S3CMD_OPTS} "${artifact}" "${S3_URL}"
  uploaded="true"
else
  echo "==> No remote configured (RCLONE_REMOTE or S3_URL). Skipping upload."
fi

# Cleanup local if uploaded
if [[ "${uploaded}" == "true" && "${KEEP_LOCAL}" != "true" ]]; then
  rm -f "${artifact}"
  echo "==> Local artifact removed after upload."
fi

echo "==> Backup complete."
