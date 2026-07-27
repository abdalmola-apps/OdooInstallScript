#!/bin/bash

# ==============================================================================
# Odoo Instance Update Script
#
# Pulls the latest commits on the instance's own Odoo branch, reinstalls Python
# requirements if they changed, and restarts the service.
#
# Source code only by default. Module *data* — the database side of an upgrade —
# is a separate, irreversible operation behind -m.
#
# Usage:
#   sudo ./odoo_update.sh -u <username> [-m] [-n] [-y]
#
# Author: abdalmola
# License: LGPL-3
# ==============================================================================

set -euo pipefail

readonly SCRIPT_VERSION="1.0.0"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

OE_USER=""
UPGRADE_MODULES=false
SKIP_BACKUP=false
ASSUME_YES=false

log_info()    { echo -e "${BLUE}[INFO $(date '+%H:%M:%S')]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN $(date '+%H:%M:%S')]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR $(date '+%H:%M:%S')]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK   $(date '+%H:%M:%S')]${NC} $*"; }

validate_username() {
    [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

usage() {
    cat <<EOF
Odoo Instance Update Script v${SCRIPT_VERSION}

Usage: sudo $0 -u <username> [OPTIONS]

Required:
  -u <username>    Odoo system user

Options:
  -m               Also upgrade module data (odoo-bin -u all) on every database
                   owned by this user. Rewrites the database and cannot be
                   undone — every database is backed up first unless -n.
  -n               Skip the pre-upgrade backup. Only meaningful with -m.
  -y               Do not ask for confirmation.
  -h               Show this help message

Without -m this updates source code only: git, pip, restart. That is safe to
run on a live instance and is what you want for a patch-level update on the
same series (18.0 -> 18.0). Jumping series (17.0 -> 18.0) is a migration, not
an update — this script will not do it.

Examples:
  # Code only — pull, reinstall changed requirements, restart
  sudo $0 -u odoo18

  # Code plus module data, backing up first
  sudo $0 -u odoo18 -m
EOF
    exit 0
}

while getopts ":u:mnyh" opt; do
    case "$opt" in
        u) OE_USER="$OPTARG" ;;
        m) UPGRADE_MODULES=true ;;
        n) SKIP_BACKUP=true ;;
        y) ASSUME_YES=true ;;
        h) usage ;;
        :) log_error "Option -$OPTARG requires an argument."; exit 1 ;;
        *) log_error "Unknown option: -$OPTARG"; usage ;;
    esac
done

# ==============================================================================
# Validation
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)."
    exit 1
fi

if [ -z "$OE_USER" ]; then
    log_error "Username is required. Use -u <username>."
    exit 1
fi

if ! validate_username "$OE_USER"; then
    log_error "Invalid username: '$OE_USER'."
    exit 1
fi

if ! id -u "$OE_USER" >/dev/null 2>&1; then
    log_error "System user '$OE_USER' does not exist."
    exit 1
fi

OE_HOME="/home/$OE_USER"
OE_HOME_EXT="$OE_HOME/odoo"
OE_SERVICE="${OE_USER}-odoo.service"
VENV="$OE_HOME_EXT/venv"

ODOO_CONF=""
for candidate in "$OE_HOME/${OE_USER}-odoo.conf" "$OE_HOME/odoo.conf"; do
    if [ -f "$candidate" ]; then
        ODOO_CONF="$candidate"
        break
    fi
done

for required in "$OE_HOME_EXT/.git" "$VENV/bin/python3" "$OE_HOME_EXT/odoo-bin"; do
    if [ ! -e "$required" ]; then
        log_error "Not an instance installed by this toolkit: $required is missing."
        exit 1
    fi
done

if [ -z "$ODOO_CONF" ]; then
    log_error "No Odoo config found in $OE_HOME."
    exit 1
fi

# ==============================================================================
# Inspect
# ==============================================================================

# Everything that touches the checkout runs as the instance user: the tree is
# owned by them, and a root-created object here would break the next update.
as_odoo() { sudo -u "$OE_USER" -H "$@"; }

BRANCH="$(as_odoo git -C "$OE_HOME_EXT" rev-parse --abbrev-ref HEAD)"
OLD_COMMIT="$(as_odoo git -C "$OE_HOME_EXT" rev-parse --short HEAD)"

if [ "$BRANCH" = "HEAD" ]; then
    log_error "The checkout is on a detached HEAD, not a release branch."
    log_error "Refusing to guess which branch to update to."
    exit 1
fi

log_info "=== Odoo Update v${SCRIPT_VERSION} ==="
log_info "Instance: $OE_USER   Branch: $BRANCH   At: $OLD_COMMIT"

log_info "Fetching origin/$BRANCH..."
# --depth 1 keeps a shallow clone shallow; the installer clones that way and a
# full unshallow here would pull ~2GB of history nobody asked for.
as_odoo git -C "$OE_HOME_EXT" fetch --depth 1 origin "$BRANCH"

NEW_COMMIT="$(as_odoo git -C "$OE_HOME_EXT" rev-parse --short FETCH_HEAD)"

if [ "$OLD_COMMIT" = "$NEW_COMMIT" ]; then
    log_success "Already up to date at $OLD_COMMIT. Nothing to do."
    if [ "$UPGRADE_MODULES" = false ]; then
        exit 0
    fi
    log_info "Continuing anyway because -m was given."
fi

# ==============================================================================
# Confirm
# ==============================================================================

echo ""
echo -e "${BLUE}Instance:${NC}  $OE_USER ($BRANCH)"
echo -e "${BLUE}Source:${NC}    $OLD_COMMIT -> $NEW_COMMIT"
if [ "$UPGRADE_MODULES" = true ]; then
    echo -e "${BLUE}Modules:${NC}   ${YELLOW}-u all on every database owned by $OE_USER${NC}"
    if [ "$SKIP_BACKUP" = true ]; then
        echo -e "${BLUE}Backup:${NC}    ${RED}skipped (-n)${NC}"
    else
        echo -e "${BLUE}Backup:${NC}    taken first"
    fi
else
    echo -e "${BLUE}Modules:${NC}   not upgraded (add -m)"
fi
echo -e "${BLUE}Service:${NC}   $OE_SERVICE will restart"
echo ""

if [ "$ASSUME_YES" = false ]; then
    read -rp "Proceed? (yes/no) [no]: " REPLY_GO || REPLY_GO="no"
    if [ "${REPLY_GO,,}" != "yes" ]; then
        log_info "Aborted. Nothing was changed."
        exit 0
    fi
fi

# ==============================================================================
# Backup (only when module data is about to be rewritten)
# ==============================================================================

if [ "$UPGRADE_MODULES" = true ] && [ "$SKIP_BACKUP" = false ]; then
    BACKUP_SCRIPT=""
    for c in "$SCRIPT_DIR/odoo_backup.sh" "$OE_HOME/odoo_backup.sh"; do
        [ -f "$c" ] && { BACKUP_SCRIPT="$c"; break; }
    done

    if [ -n "$BACKUP_SCRIPT" ]; then
        log_info "Backing up before the module upgrade..."
        bash "$BACKUP_SCRIPT" -u "$OE_USER" -f
        log_success "Backup complete."
    else
        log_error "odoo_backup.sh not found — refusing to run -u all with no backup."
        log_error "Put odoo_backup.sh beside this script, or pass -n to accept the risk."
        exit 1
    fi
fi

# ==============================================================================
# Update source
# ==============================================================================

# reset --hard, never `git clean`: the venv lives at odoo/venv, inside the work
# tree but untracked, so a clean would delete the interpreter mid-update.
log_info "Updating source to $NEW_COMMIT..."
OLD_REQ_HASH="$(sha256sum "$OE_HOME_EXT/requirements.txt" | cut -d' ' -f1)"
as_odoo git -C "$OE_HOME_EXT" reset --hard FETCH_HEAD
NEW_REQ_HASH="$(sha256sum "$OE_HOME_EXT/requirements.txt" | cut -d' ' -f1)"
log_success "Source now at $NEW_COMMIT."

if [ "$OLD_REQ_HASH" != "$NEW_REQ_HASH" ]; then
    log_info "requirements.txt changed — reinstalling Python dependencies..."
    as_odoo "$VENV/bin/pip" install --no-cache-dir -r "$OE_HOME_EXT/requirements.txt"
    log_success "Dependencies updated."
else
    log_info "requirements.txt unchanged — skipping pip."
fi

# ==============================================================================
# Module data upgrade
# ==============================================================================

if [ "$UPGRADE_MODULES" = true ]; then
    DATABASES=$(sudo -u postgres psql -tAc \
        "SELECT datname FROM pg_database
         WHERE datdba = (SELECT oid FROM pg_roles WHERE rolname = '$OE_USER')
           AND datname NOT IN ('postgres', 'template0', 'template1')
         ORDER BY datname;" 2>/dev/null) || true

    if [ -z "$DATABASES" ]; then
        log_warn "No databases owned by '$OE_USER' — nothing to upgrade."
    else
        # Stop first: -u all takes an exclusive grip on the registry, and a
        # running worker serving requests against half-upgraded schema is worse
        # than a minute of downtime.
        log_info "Stopping $OE_SERVICE for the upgrade..."
        systemctl stop "$OE_SERVICE" || true

        UPGRADE_FAILED=0
        for db in $DATABASES; do
            log_info "Upgrading modules in '$db'..."
            if as_odoo "$VENV/bin/python3" "$OE_HOME_EXT/odoo-bin" \
                    -c "$ODOO_CONF" -d "$db" -u all \
                    --workers=0 --no-http --stop-after-init --log-level=warn; then
                log_success "  '$db' upgraded."
            else
                log_error "  '$db' FAILED to upgrade — restore it from the backup."
                UPGRADE_FAILED=$((UPGRADE_FAILED + 1))
            fi
        done
    fi
fi

# ==============================================================================
# Restart & verify
# ==============================================================================

log_info "Restarting $OE_SERVICE..."
systemctl restart "$OE_SERVICE"

# systemctl returns once the process is forked, which is not the same as Odoo
# having survived its own startup — wait for the port before claiming success.
OE_PORT="$(awk -F'[ =]+' '/^(http_port|xmlrpc_port)/{print $2; exit}' "$ODOO_CONF" 2>/dev/null || true)"
OE_PORT="${OE_PORT:-8069}"

for _ in $(seq 1 60); do
    ss -Hltn "sport = :$OE_PORT" 2>/dev/null | grep -q . && break
    sleep 1
done

echo ""
if ss -Hltn "sport = :$OE_PORT" 2>/dev/null | grep -q .; then
    log_success "Update complete — $OE_USER is at $NEW_COMMIT and listening on $OE_PORT."
else
    log_error "Odoo is NOT listening on port $OE_PORT after the update."
    log_error "  systemctl status $OE_SERVICE --no-pager"
    log_error "  tail -50 $OE_HOME/data/odoo-server.log"
    log_error "Roll back with: sudo -u $OE_USER git -C $OE_HOME_EXT reset --hard $OLD_COMMIT"
    exit 1
fi

if [ "${UPGRADE_FAILED:-0}" -gt 0 ]; then
    log_error "$UPGRADE_FAILED database(s) failed to upgrade — see above."
    exit 1
fi
