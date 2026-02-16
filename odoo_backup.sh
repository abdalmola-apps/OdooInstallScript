#!/bin/bash

# ==============================================================================
# Odoo Database Backup Script
#
# Discovers all PostgreSQL databases owned by the Odoo system user, sorts them
# by latest write activity (most recent first), and creates compressed backups.
# Optionally includes filestore directories.
#
# Usage:
#   sudo ./odoo_backup.sh -u <username> [-d <backup_dir>] [-r <days>] [-f] [-q]
#
# Designed for cron:
#   0 2 * * * /home/<user>/odoo_backup.sh -u <user> -f -q >> /home/<user>/data/backup.log 2>&1
#
# Author: abdalmola
# License: LGPL-3
# ==============================================================================

set -euo pipefail

# ==============================================================================
# Constants & Colors
# ==============================================================================

readonly SCRIPT_VERSION="1.0.0"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# ==============================================================================
# Defaults
# ==============================================================================

OE_USER=""
BACKUP_DIR=""
RETENTION_DAYS=30
INCLUDE_FILESTORE=false
QUIET=false

# ==============================================================================
# Utility Functions
# ==============================================================================

log_info() {
    if [ "$QUIET" = false ]; then
        echo -e "${BLUE}[INFO $(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"
    fi
}

log_warn() {
    echo -e "${YELLOW}[WARN $(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR $(date '+%Y-%m-%d %H:%M:%S')]${NC} $*" >&2
}

log_success() {
    if [ "$QUIET" = false ]; then
        echo -e "${GREEN}[OK   $(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"
    fi
}

# ==============================================================================
# Usage / Help
# ==============================================================================

usage() {
    cat <<EOF
Odoo Database Backup Script v${SCRIPT_VERSION}

Usage: sudo $0 -u <username> [OPTIONS]

Required:
  -u <username>    Odoo system user (derives DB user & paths)

Options:
  -d <backup_dir>  Override backup directory (default: /home/<user>/backups)
  -r <days>        Retention: delete backups older than N days (default: 30)
  -f               Include filestore in backup (tar the data_dir/filestore)
  -q               Quiet mode — only output errors (for cron)
  -h               Show this help message

Examples:
  # Interactive backup with filestore
  sudo $0 -u odoo18 -f

  # Cron: daily at 2 AM, quiet, 14-day retention
  0 2 * * * /home/odoo18/odoo_backup.sh -u odoo18 -f -q -r 14 >> /home/odoo18/data/backup.log 2>&1
EOF
    exit 0
}

# ==============================================================================
# Parse Arguments
# ==============================================================================

while getopts ":u:d:r:fqh" opt; do
    case "$opt" in
        u) OE_USER="$OPTARG" ;;
        d) BACKUP_DIR="$OPTARG" ;;
        r) RETENTION_DAYS="$OPTARG" ;;
        f) INCLUDE_FILESTORE=true ;;
        q) QUIET=true ;;
        h) usage ;;
        :) log_error "Option -$OPTARG requires an argument."; exit 1 ;;
        *) log_error "Unknown option: -$OPTARG"; usage ;;
    esac
done

# ==============================================================================
# Validation
# ==============================================================================

if [ -z "$OE_USER" ]; then
    log_error "Username is required. Use -u <username>."
    echo "Run '$0 -h' for help."
    exit 1
fi

if ! id -u "$OE_USER" >/dev/null 2>&1; then
    log_error "System user '$OE_USER' does not exist."
    exit 1
fi

if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || [ "$RETENTION_DAYS" -lt 1 ]; then
    log_error "Retention days must be a positive integer. Got: $RETENTION_DAYS"
    exit 1
fi

# ==============================================================================
# Derive Paths
# ==============================================================================

OE_HOME="/home/$OE_USER"
OE_DATA_DIR="$OE_HOME/data"

if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$OE_HOME/backups"
fi

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

# ==============================================================================
# Start Backup
# ==============================================================================

log_info "=== Odoo Backup Script v${SCRIPT_VERSION} ==="
log_info "User: $OE_USER | Backup dir: $BACKUP_DIR | Retention: ${RETENTION_DAYS} days"
log_info "Filestore: $INCLUDE_FILESTORE | Timestamp: $TIMESTAMP"

# Create backup directory if missing
if [ ! -d "$BACKUP_DIR" ]; then
    log_info "Creating backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    chown "$OE_USER:$OE_USER" "$BACKUP_DIR"
fi

# ==============================================================================
# Step 1: Discover Databases
# ==============================================================================

log_info "Discovering databases owned by '$OE_USER'..."

DATABASES=$(sudo -u postgres psql -tAc \
    "SELECT datname FROM pg_database
     WHERE datdba = (SELECT oid FROM pg_roles WHERE rolname = '$OE_USER')
       AND datname NOT IN ('postgres', 'template0', 'template1')
     ORDER BY datname;" 2>/dev/null) || true

if [ -z "$DATABASES" ]; then
    log_warn "No databases found for user '$OE_USER'. Nothing to back up."
    exit 0
fi

DB_COUNT=$(echo "$DATABASES" | wc -l)
log_info "Found $DB_COUNT database(s)."

# ==============================================================================
# Step 2: Sort by Activity (most recent first)
# ==============================================================================

log_info "Querying last activity for each database..."

declare -A DB_ACTIVITY

for db in $DATABASES; do
    # Try to get the latest write_date from res_users (present in all Odoo DBs)
    LAST_WRITE=$(sudo -u "$OE_USER" psql -d "$db" -tAc \
        "SELECT COALESCE(MAX(write_date)::text, '1970-01-01') FROM res_users;" 2>/dev/null) || true

    if [ -z "$LAST_WRITE" ] || [ "$LAST_WRITE" = "" ]; then
        # Non-Odoo database or query failed — use epoch as fallback
        LAST_WRITE="1970-01-01"
        log_warn "  $db: could not query activity (non-Odoo DB?), sorting last"
    else
        log_info "  $db: last activity $LAST_WRITE"
    fi

    DB_ACTIVITY["$db"]="$LAST_WRITE"
done

# Sort databases by activity date (most recent first)
SORTED_DBS=$(
    for db in "${!DB_ACTIVITY[@]}"; do
        echo "${DB_ACTIVITY[$db]} $db"
    done | sort -r | awk '{print $2}'
)

log_info "Backup order (most active first):"
PRIORITY=1
for db in $SORTED_DBS; do
    log_info "  $PRIORITY. $db (${DB_ACTIVITY[$db]})"
    PRIORITY=$((PRIORITY + 1))
done

# ==============================================================================
# Step 3: Backup Each Database
# ==============================================================================

BACKED_UP=0
FAILED=0

for db in $SORTED_DBS; do
    DUMP_FILE="$BACKUP_DIR/${db}_${TIMESTAMP}.dump"

    log_info "Backing up database '$db'..."

    if sudo -u "$OE_USER" pg_dump -Fc -Z5 "$db" -f "$DUMP_FILE" 2>/dev/null; then
        DUMP_SIZE=$(du -sh "$DUMP_FILE" | cut -f1)
        log_success "  Database dump: $DUMP_FILE ($DUMP_SIZE)"
        BACKED_UP=$((BACKED_UP + 1))
    else
        log_error "  Failed to dump database '$db'."
        rm -f "$DUMP_FILE"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Filestore backup (optional)
    if [ "$INCLUDE_FILESTORE" = true ]; then
        FILESTORE_DIR="$OE_DATA_DIR/filestore/$db"
        if [ -d "$FILESTORE_DIR" ]; then
            TAR_FILE="$BACKUP_DIR/${db}_filestore_${TIMESTAMP}.tar.gz"
            log_info "  Backing up filestore for '$db'..."

            if tar -czf "$TAR_FILE" -C "$OE_DATA_DIR/filestore" "$db" 2>/dev/null; then
                TAR_SIZE=$(du -sh "$TAR_FILE" | cut -f1)
                log_success "  Filestore archive: $TAR_FILE ($TAR_SIZE)"
            else
                log_error "  Failed to archive filestore for '$db'."
                rm -f "$TAR_FILE"
            fi
        else
            log_info "  No filestore directory for '$db'. Skipping filestore backup."
        fi
    fi
done

# ==============================================================================
# Step 4: Cleanup Old Backups
# ==============================================================================

log_info "Cleaning up backups older than $RETENTION_DAYS days..."

CLEANED_DUMPS=$(find "$BACKUP_DIR" -name "*.dump" -mtime +"$RETENTION_DAYS" -type f 2>/dev/null | wc -l)
CLEANED_TARS=$(find "$BACKUP_DIR" -name "*.tar.gz" -mtime +"$RETENTION_DAYS" -type f 2>/dev/null | wc -l)

find "$BACKUP_DIR" -name "*.dump" -mtime +"$RETENTION_DAYS" -type f -delete 2>/dev/null || true
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +"$RETENTION_DAYS" -type f -delete 2>/dev/null || true

CLEANED=$((CLEANED_DUMPS + CLEANED_TARS))
if [ "$CLEANED" -gt 0 ]; then
    log_info "Removed $CLEANED old backup file(s) ($CLEANED_DUMPS dumps, $CLEANED_TARS archives)."
else
    log_info "No old backups to clean up."
fi

# ==============================================================================
# Summary
# ==============================================================================

TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)

echo ""
log_info "=== Backup Summary ==="
log_info "Databases backed up: $BACKED_UP / $DB_COUNT"
if [ "$FAILED" -gt 0 ]; then
    log_warn "Failed: $FAILED"
fi
log_info "Old files cleaned: $CLEANED"
log_info "Backup directory size: $TOTAL_SIZE"
log_info "Location: $BACKUP_DIR"
log_success "Backup complete."
