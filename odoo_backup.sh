#!/bin/bash

# ==============================================================================
# Odoo Database Backup Script
#
# Discovers all PostgreSQL databases owned by the Odoo system user, sorts them
# by latest write activity (most recent first), and backs each one up with
# click-odoo-backupdb.
#
# Output is one Odoo-native .zip per database (manifest.json + dump.sql +
# filestore), restorable through Odoo's own web interface or with
# click-odoo-restoredb — rather than a pg_dump plus a separate filestore
# tarball that have to be restored as two steps that can drift apart.
#
# Requires click-odoo-contrib in the instance venv (this repo's
# requirements.txt installs it).
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
  -f               Include the filestore in the backup
  -q               Quiet mode — only output errors (for cron)
  -h               Show this help message

Output:
  One <dbname>_<timestamp>.zip per database (manifest.json + dump.sql +
  filestore). Restore through Odoo's web interface, or:
    sudo -u <user> /home/<user>/odoo/venv/bin/click-odoo-restoredb \\
        -c /home/<user>/<user>-odoo.conf --neutralize <newdb> <backup.zip>
  (--neutralize disables crons and outgoing mail — use it for staging copies.)

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

if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$OE_HOME/backups"
fi

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"

# click-odoo-backupdb imports odoo, so it has to be the instance's own venv.
BACKUPDB="$OE_HOME/odoo/venv/bin/click-odoo-backupdb"
if [ ! -x "$BACKUPDB" ]; then
    log_error "click-odoo-backupdb not found at $BACKUPDB"
    log_error "Install it into the instance venv:"
    log_error "  sudo -u $OE_USER $OE_HOME/odoo/venv/bin/pip install click-odoo-contrib"
    exit 1
fi

# -c is required: without it click-odoo cannot resolve data_dir, so it would
# look for the filestore in the wrong place and back up nothing.
ODOO_CONF=""
for candidate in "$OE_HOME/${OE_USER}-odoo.conf" "$OE_HOME/odoo.conf"; do
    if [ -f "$candidate" ]; then
        ODOO_CONF="$candidate"
        break
    fi
done
if [ -z "$ODOO_CONF" ]; then
    log_error "No Odoo config found in $OE_HOME (looked for ${OE_USER}-odoo.conf, odoo.conf)."
    exit 1
fi

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

# Sort databases by activity date (most recent first).
# Tab-separated, not space: write_date renders as "2026-07-01 10:00:00.123456",
# so `awk '{print $2}'` on a space-joined line returned the time instead of the
# database name — every real Odoo database then blew up on an unbound
# DB_ACTIVITY lookup under `set -u`.
SORTED_DBS=$(
    for db in "${!DB_ACTIVITY[@]}"; do
        printf '%s\t%s\n' "${DB_ACTIVITY[$db]}" "$db"
    done | sort -r | cut -f2
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

# Keep -f meaning "opt in to the filestore", matching this script's existing
# flag and the installer's cron line. click-odoo-backupdb defaults the other way.
if [ "$INCLUDE_FILESTORE" = true ]; then
    FILESTORE_FLAG="--filestore"
else
    FILESTORE_FLAG="--no-filestore"
fi

for db in $SORTED_DBS; do
    ZIP_FILE="$BACKUP_DIR/${db}_${TIMESTAMP}.zip"

    log_info "Backing up database '$db'..."

    # Runs as the Odoo user: the config is chmod 640 and the filestore is owned
    # by that user. -H so click-odoo resolves the right HOME.
    if sudo -u "$OE_USER" -H "$BACKUPDB" -c "$ODOO_CONF" \
            --format zip "$FILESTORE_FLAG" "$db" "$ZIP_FILE"; then
        ZIP_SIZE=$(du -sh "$ZIP_FILE" | cut -f1)
        log_success "  Backup: $ZIP_FILE ($ZIP_SIZE)"
        BACKED_UP=$((BACKED_UP + 1))
    else
        log_error "  Failed to back up database '$db'."
        # A partial zip is worse than none — it looks restorable and is not.
        rm -f "$ZIP_FILE"
        FAILED=$((FAILED + 1))
        continue
    fi
done

# ==============================================================================
# Step 4: Cleanup Old Backups
# ==============================================================================

log_info "Cleaning up backups older than $RETENTION_DAYS days..."

# .dump/.tar.gz are the pre-click-odoo layout — still aged out so backups made
# by an older version of this script do not accumulate forever.
CLEANED=0
for pattern in "*.zip" "*.dump" "*.tar.gz"; do
    N=$(find "$BACKUP_DIR" -name "$pattern" -mtime +"$RETENTION_DAYS" -type f 2>/dev/null | wc -l)
    find "$BACKUP_DIR" -name "$pattern" -mtime +"$RETENTION_DAYS" -type f -delete 2>/dev/null || true
    CLEANED=$((CLEANED + N))
done

if [ "$CLEANED" -gt 0 ]; then
    log_info "Removed $CLEANED backup file(s) older than $RETENTION_DAYS days."
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

# Exit non-zero if anything failed, so cron reports it. A backup job that
# fails every night while exiting 0 is indistinguishable from one that works.
if [ "$FAILED" -gt 0 ]; then
    log_error "Backup finished with $FAILED failure(s)."
    exit 1
fi

log_success "Backup complete."
