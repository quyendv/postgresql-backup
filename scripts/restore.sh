#!/bin/bash
set -euo pipefail

# ─── Color output ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Validate required env vars ──────────────────────────────────────────────
REQUIRED_VARS=(
    POSTGRES_HOST POSTGRES_PORT POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB
    S3_ACCESS_KEY S3_SECRET_KEY S3_ENDPOINT S3_BUCKET S3_REGION S3_PATH
)
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log_error "Required environment variable '$var' is not set."
        exit 1
    fi
done

POSTGRES_MAINTENANCE_DB="${POSTGRES_MAINTENANCE_DB:-postgres}"
RESTORE_DROP_DB="${RESTORE_DROP_DB:-false}"
RESTORE_CLEAN="${RESTORE_CLEAN:-false}"
WORK_DIR="${RESTORE_WORK_DIR:-/tmp/postgresql-restore}"
DUMP_NAME="postgresql_backup.dump.gz"

# ─── Normalize booleans ──────────────────────────────────────────────────────
is_true() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── Header ──────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════"
log_info "PostgreSQL Restore Job Started"
log_info "Timestamp  : $(date '+%Y-%m-%d %H:%M:%S %Z')"
log_info "Target     : ${POSTGRES_HOST}:${POSTGRES_PORT} / ${POSTGRES_DB}"
log_info "S3 prefix  : s3://${S3_BUCKET}/${S3_PATH}/"
log_info "RESTORE_DROP_DB: ${RESTORE_DROP_DB}"
log_info "RESTORE_CLEAN  : ${RESTORE_CLEAN}"
echo "════════════════════════════════════════════════════"

# ─── Step 1: Configure AWS CLI ───────────────────────────────────────────────
log_info "Configuring AWS credentials..."
aws configure set aws_access_key_id     "${S3_ACCESS_KEY}"
aws configure set aws_secret_access_key "${S3_SECRET_KEY}"
aws configure set default.region        "${S3_REGION}"
log_success "AWS CLI configured."

# ─── Step 2: Resolve backup timestamp folder ───────────────────────────────
if [[ -n "${RESTORE_TIMESTAMP:-}" ]]; then
    BACKUP_TS="${RESTORE_TIMESTAMP}"
    log_info "Using RESTORE_TIMESTAMP=${BACKUP_TS}"
    if ! aws s3 ls "s3://${S3_BUCKET}/${S3_PATH}/${BACKUP_TS}/${DUMP_NAME}" \
        --endpoint-url "${S3_ENDPOINT}" &>/dev/null; then
        log_error "Object not found: s3://${S3_BUCKET}/${S3_PATH}/${BACKUP_TS}/${DUMP_NAME}"
        exit 1
    fi
else
    log_info "RESTORE_TIMESTAMP unset — selecting latest backup folder..."
    BACKUP_TS=$(
        aws s3 ls "s3://${S3_BUCKET}/${S3_PATH}/" \
            --endpoint-url "${S3_ENDPOINT}" 2>/dev/null \
            | awk '{print $2}' \
            | grep -E '^[0-9]{8}_' \
            | sed 's|/$||' \
            | sort -r \
            | head -1
    ) || true
    if [[ -z "${BACKUP_TS}" ]]; then
        log_error "No backup folders matching YYYYMMDD_* under s3://${S3_BUCKET}/${S3_PATH}/"
        exit 1
    fi
    log_success "Latest backup folder: ${BACKUP_TS}"
fi

S3_URI="s3://${S3_BUCKET}/${S3_PATH}/${BACKUP_TS}/${DUMP_NAME}"

# ─── Step 3: Download dump ─────────────────────────────────────────────────────
mkdir -p "${WORK_DIR}"
LOCAL_DUMP="${WORK_DIR}/${DUMP_NAME}"
log_info "Downloading ${S3_URI} ..."
aws s3 cp "${S3_URI}" "${LOCAL_DUMP}" \
    --endpoint-url "${S3_ENDPOINT}" \
    --no-progress

DUMP_SIZE=$(stat -c%s "${LOCAL_DUMP}" 2>/dev/null || echo 0)
if [[ ! -s "${LOCAL_DUMP}" ]] || [[ "${DUMP_SIZE}" -lt 512 ]]; then
    log_error "Downloaded file is empty or too small (${DUMP_SIZE} bytes)."
    exit 1
fi
log_success "Download complete — $(du -sh "${LOCAL_DUMP}" | cut -f1)"

# ─── Step 4: Wait for PostgreSQL ─────────────────────────────────────────────
export PGPASSWORD="${POSTGRES_PASSWORD}"
log_info "Waiting for PostgreSQL..."
for i in $(seq 1 30); do
    if pg_isready -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -q; then
        log_success "PostgreSQL is ready."
        break
    fi
    if [[ "${i}" -eq 30 ]]; then
        log_error "PostgreSQL not reachable after 30 attempts."
        exit 1
    fi
    sleep 2
done

log_info "pg_restore version: $(pg_restore --version)"

# ─── Step 5: Optional drop/recreate database ─────────────────────────────────
if is_true "${RESTORE_DROP_DB}"; then
    log_warn "RESTORE_DROP_DB=true — dropping and recreating database '${POSTGRES_DB}' ..."
    psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" \
        -d "${POSTGRES_MAINTENANCE_DB}" -v ON_ERROR_STOP=1 <<EOF
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${POSTGRES_DB}";
CREATE DATABASE "${POSTGRES_DB}";
EOF
    log_success "Database recreated."
else
    log_info "Checking target database exists (set RESTORE_DROP_DB=true to drop/recreate)..."
    EXISTS=$(
        psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" \
            -d "${POSTGRES_MAINTENANCE_DB}" -t -A -c \
            "SELECT 1 FROM pg_database WHERE datname = '${POSTGRES_DB}';" 2>/dev/null || echo ""
    )
    if [[ "${EXISTS}" != "1" ]]; then
        log_error "Database '${POSTGRES_DB}' does not exist. Create it first or set RESTORE_DROP_DB=true."
        exit 1
    fi
    log_success "Target database exists."
fi

# ─── Step 6: pg_restore ──────────────────────────────────────────────────────
PG_ARGS=(
    -h "${POSTGRES_HOST}"
    -p "${POSTGRES_PORT}"
    -U "${POSTGRES_USER}"
    -d "${POSTGRES_DB}"
    --no-owner
    --no-privileges
    --verbose
)

if is_true "${RESTORE_CLEAN}"; then
    PG_ARGS+=(--clean --if-exists)
    log_info "RESTORE_CLEAN=true — using --clean --if-exists"
fi

log_info "Starting pg_restore from ${DUMP_NAME} (custom format, gzip) ..."
set +e
gunzip -c "${LOCAL_DUMP}" | pg_restore "${PG_ARGS[@]}"
RESTORE_CODE=$?
set -e

if [[ "${RESTORE_CODE}" -eq 0 ]]; then
    log_success "pg_restore completed successfully."
else
    log_warn "pg_restore exited with code ${RESTORE_CODE} (warnings are common for custom dumps)."
    TABLE_COUNT=$(
        psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" \
            -d "${POSTGRES_DB}" -t -A -c \
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema');" \
            2>/dev/null || echo "0"
    )
    if [[ "${TABLE_COUNT}" =~ ^[0-9]+$ ]] && [[ "${TABLE_COUNT}" -gt 0 ]]; then
        log_success "Restore appears OK — ${TABLE_COUNT} non-system tables found."
    else
        log_error "pg_restore failed and no user tables found."
        exit 1
    fi
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────
rm -rf "${WORK_DIR}"
log_success "Local temp removed."

echo "════════════════════════════════════════════════════"
log_success "PostgreSQL Restore completed at $(date '+%Y-%m-%d %H:%M:%S %Z')"
log_info "Source backup folder: ${BACKUP_TS}"
echo "════════════════════════════════════════════════════"
