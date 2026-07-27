#!/bin/bash

# ==============================================================================
# Odoo Instance Removal Script
#
# Removes everything one instance owns: the service, its databases, the
# PostgreSQL role, the home directory and filestore, the config, the logrotate
# rule, the backup cron entry, the Nginx site, the UFW rule, and the installer's
# saved state.
#
# This deletes production data. It takes a full backup first, shows exactly what
# it is about to remove, and requires the username to be typed back — there is
# no -y, and -n (skip backup) is the only way to lose the data outright.
#
# Usage:
#   sudo ./odoo_remove.sh -u <username> [-n] [-k]
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
readonly SAFE_DIR="/root/abo-removed"

OE_USER=""
SKIP_BACKUP=false
KEEP_DATABASES=false

log_info()    { echo -e "${BLUE}[INFO $(date '+%H:%M:%S')]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN $(date '+%H:%M:%S')]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR $(date '+%H:%M:%S')]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK   $(date '+%H:%M:%S')]${NC} $*"; }

validate_username() {
    [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

usage() {
    cat <<EOF
Odoo Instance Removal Script v${SCRIPT_VERSION}

Usage: sudo $0 -u <username> [OPTIONS]

Required:
  -u <username>    Odoo system user to remove

Options:
  -k               Keep the databases and the PostgreSQL role. Removes the
                   service, files, Nginx site and cron only.
  -n               Skip the safety backup. The databases and filestore are
                   then gone for good.
  -h               Show this help message

Always asks for the username to be typed back before touching anything. There
is deliberately no unattended mode.

If the PostgreSQL role owns objects in databases other than this instance's,
the script stops before removing anything and tells you what to reassign.

Examples:
  # Remove an instance, backing it up to $SAFE_DIR first
  sudo $0 -u odoo18

  # Decommission the server side but keep the databases
  sudo $0 -u odoo18 -k
EOF
    exit 0
}

while getopts ":u:nkh" opt; do
    case "$opt" in
        u) OE_USER="$OPTARG" ;;
        n) SKIP_BACKUP=true ;;
        k) KEEP_DATABASES=true ;;
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
    log_error "System user '$OE_USER' does not exist. Nothing to remove."
    exit 1
fi

# A typo here would delete the wrong account, and some of these are unrecoverable.
case "$OE_USER" in
    root|postgres|www-data|nobody|ubuntu|daemon|sync|bin|sys)
        log_error "Refusing to remove system account '$OE_USER'."
        exit 1
        ;;
esac

OE_UID="$(id -u "$OE_USER")"
if [ "$OE_UID" -lt 1000 ]; then
    log_error "'$OE_USER' has UID $OE_UID — that is a system account, not an Odoo instance."
    exit 1
fi

OE_HOME="/home/$OE_USER"
OE_SERVICE="${OE_USER}-odoo.service"
STATE_DIR="/var/lib/odoo-install"

# ==============================================================================
# Inventory — work out what exists before promising to delete it
# ==============================================================================

log_info "=== Odoo Removal v${SCRIPT_VERSION} ==="
log_info "Taking inventory of '$OE_USER'..."

HAS_SERVICE=false
[ -f "/etc/systemd/system/$OE_SERVICE" ] && HAS_SERVICE=true

DATABASES=""
if command -v psql >/dev/null 2>&1; then
    DATABASES=$(sudo -u postgres psql -tAc \
        "SELECT datname FROM pg_database
         WHERE datdba = (SELECT oid FROM pg_roles WHERE rolname = '$OE_USER')
           AND datname NOT IN ('postgres', 'template0', 'template1')
         ORDER BY datname;" 2>/dev/null) || true
fi

HAS_ROLE=false
if command -v psql >/dev/null 2>&1 && \
   sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$OE_USER'" 2>/dev/null | grep -q 1; then
    HAS_ROLE=true
fi

# Does the role own anything outside the databases we are about to drop? If so
# DROP ROLE will fail, and finding that out after the databases are gone is too
# late to be useful. pg_shdepend is the cluster-wide record of role
# dependencies; rows whose containing database is itself owned by this role are
# excluded, because those databases are being dropped anyway.
ROLE_BLOCKERS=""
if [ "$HAS_ROLE" = true ] && [ "$KEEP_DATABASES" = false ]; then
    ROLE_BLOCKERS=$(sudo -u postgres psql -tAc "
        SELECT DISTINCT COALESCE(d.datname, 'cluster-wide object')
        FROM pg_shdepend s
        LEFT JOIN pg_database d ON d.oid = s.dbid
        WHERE s.refobjid = (SELECT oid FROM pg_roles WHERE rolname = '$OE_USER')
          AND s.deptype IN ('o', 'a')
          AND CASE
                WHEN s.dbid = 0 THEN s.classid <> 'pg_database'::regclass
                ELSE d.datdba IS DISTINCT FROM
                     (SELECT oid FROM pg_roles WHERE rolname = '$OE_USER')
              END;" 2>/dev/null) || true
fi

HOME_SIZE="n/a"
[ -d "$OE_HOME" ] && HOME_SIZE="$(du -sh "$OE_HOME" 2>/dev/null | cut -f1)"

# The Nginx site is named after the domain, not the user — find it by the
# per-user upstream block odoo_nginx.sh writes into it.
NGINX_SITES=""
if [ -d /etc/nginx/sites-available ]; then
    NGINX_SITES=$(grep -rlE "^[[:space:]]*upstream[[:space:]]+${OE_USER}_odoo[[:space:]]*\{" \
        /etc/nginx/sites-available/ 2>/dev/null | xargs -r -n1 basename) || true
fi

HAS_LOGROTATE=false
[ -f "/etc/logrotate.d/${OE_USER}-odoo" ] && HAS_LOGROTATE=true

CRON_LINES=0
if command -v crontab >/dev/null 2>&1; then
    CRON_LINES=$(crontab -l 2>/dev/null | grep -cF "odoo_backup.sh -u $OE_USER" || true)
fi

# ==============================================================================
# Stop before touching anything if the role cannot be dropped
# ==============================================================================

if [ -n "$ROLE_BLOCKERS" ]; then
    echo ""
    log_error "Role '$OE_USER' owns objects outside this instance:"
    while read -r b; do
        if [ -n "$b" ]; then
            log_error "  - $b"
        fi
    done <<< "$ROLE_BLOCKERS"
    echo ""
    log_error "DROP ROLE would fail, so nothing has been removed."
    echo ""
    log_error "Resolve it by reassigning or dropping what the role owns. In each"
    log_error "database listed above:"
    log_error "  sudo -u postgres psql -d <database> \\"
    log_error "    -c 'REASSIGN OWNED BY \"$OE_USER\" TO postgres' \\"
    log_error "    -c 'DROP OWNED BY \"$OE_USER\"'"
    echo ""
    log_error "Or keep the databases and role with:  $0 -u $OE_USER -k"
    exit 1
fi

# ==============================================================================
# The plan
# ==============================================================================

echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║   PERMANENT REMOVAL — read this before confirming        ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Instance:   ${BLUE}$OE_USER${NC}"
echo ""

if [ "$HAS_SERVICE" = true ]; then
    echo -e "  ${RED}delete${NC}  service     $OE_SERVICE"
fi

if [ "$KEEP_DATABASES" = true ]; then
    echo -e "  ${GREEN}keep${NC}    databases   $(echo "$DATABASES" | tr '\n' ' ')"
    echo -e "  ${GREEN}keep${NC}    role        $OE_USER"
elif [ -n "$DATABASES" ]; then
    while read -r db; do
        [ -z "$db" ] && continue
        DB_SIZE="$(sudo -u postgres psql -tAc "SELECT pg_size_pretty(pg_database_size('$db'))" 2>/dev/null || echo '?')"
        echo -e "  ${RED}DROP${NC}    database    $db ($DB_SIZE)"
    done <<< "$DATABASES"
    [ "$HAS_ROLE" = true ] && echo -e "  ${RED}DROP${NC}    role        $OE_USER"
else
    echo -e "          databases   none found"
    [ "$HAS_ROLE" = true ] && echo -e "  ${RED}DROP${NC}    role        $OE_USER"
fi

if [ -d "$OE_HOME" ]; then
    echo -e "  ${RED}delete${NC}  home        $OE_HOME ($HOME_SIZE, includes the filestore)"
fi
echo -e "  ${RED}delete${NC}  account     $OE_USER (uid $OE_UID)"

if [ -n "$NGINX_SITES" ]; then
    for s in $NGINX_SITES; do
        echo -e "  ${RED}delete${NC}  nginx site  $s"
    done
    echo -e "          ${YELLOW}TLS certificates are left alone — remove with certbot delete${NC}"
fi

[ "$HAS_LOGROTATE" = true ] && echo -e "  ${RED}delete${NC}  logrotate   /etc/logrotate.d/${OE_USER}-odoo"
[ "$CRON_LINES" -gt 0 ] && echo -e "  ${RED}delete${NC}  cron        $CRON_LINES backup entry(ies) from root's crontab"
echo -e "  ${RED}delete${NC}  state       $STATE_DIR/${OE_USER}.{checkpoint,answers}"

echo ""
if [ "$SKIP_BACKUP" = true ] && [ "$KEEP_DATABASES" = false ]; then
    echo -e "  ${RED}NO BACKUP WILL BE TAKEN (-n). This is unrecoverable.${NC}"
elif [ "$KEEP_DATABASES" = false ]; then
    echo -e "  A backup is written to ${BLUE}$SAFE_DIR${NC} first."
fi
echo ""

# ==============================================================================
# Confirmation
# ==============================================================================

if [ ! -t 0 ]; then
    log_error "Refusing to remove an instance non-interactively."
    exit 1
fi

read -rp "Type the username to confirm removal: " CONFIRM || CONFIRM=""
if [ "$CONFIRM" != "$OE_USER" ]; then
    log_info "Did not match. Nothing was changed."
    exit 0
fi

# ==============================================================================
# Backup
# ==============================================================================

if [ "$SKIP_BACKUP" = false ] && [ "$KEEP_DATABASES" = false ] && [ -n "$DATABASES" ]; then
    BACKUP_SCRIPT=""
    for c in "$SCRIPT_DIR/odoo_backup.sh" "$OE_HOME/odoo_backup.sh"; do
        [ -f "$c" ] && { BACKUP_SCRIPT="$c"; break; }
    done

    if [ -z "$BACKUP_SCRIPT" ]; then
        log_error "odoo_backup.sh not found — refusing to delete databases with no backup."
        log_error "Put odoo_backup.sh beside this script, or pass -n to accept the loss."
        exit 1
    fi

    mkdir -p "$SAFE_DIR"
    chmod 700 "$SAFE_DIR"
    log_info "Backing up to $SAFE_DIR before removing anything..."

    # -r 36500 so the retention sweep cannot prune the very backup that is the
    # only remaining copy of this instance.
    if ! bash "$BACKUP_SCRIPT" -u "$OE_USER" -f -d "$SAFE_DIR" -r 36500; then
        log_error "Backup FAILED. Nothing has been removed."
        log_error "Fix the backup, or re-run with -n to remove without one."
        exit 1
    fi
    log_success "Backup written to $SAFE_DIR."
fi

# ==============================================================================
# Removal — service first, so nothing is writing while we delete
# ==============================================================================

echo ""
log_info "Removing instance '$OE_USER'..."

if [ "$HAS_SERVICE" = true ]; then
    systemctl stop "$OE_SERVICE" 2>/dev/null || true
    systemctl disable "$OE_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$OE_SERVICE"
    systemctl daemon-reload
    log_success "Service removed."
fi

if [ -n "$NGINX_SITES" ]; then
    for s in $NGINX_SITES; do
        rm -f "/etc/nginx/sites-enabled/$s" "/etc/nginx/sites-available/$s"
        log_success "Nginx site '$s' removed."
    done
    # Only reload if the remaining config is valid — a reload that fails here
    # would take down every other site on the box.
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
        log_success "Nginx reloaded."
    else
        log_warn "nginx -t fails after removal — NOT reloading. Check 'sudo nginx -t'."
    fi
fi

if [ "$CRON_LINES" -gt 0 ]; then
    { crontab -l 2>/dev/null | grep -vF "odoo_backup.sh -u $OE_USER" || true; } | crontab -
    log_success "Backup cron entry removed."
fi

if [ "$KEEP_DATABASES" = false ]; then
    if [ -n "$DATABASES" ]; then
        while read -r db; do
            [ -z "$db" ] && continue
            # Sessions survive the service stop when someone is in psql; without
            # this, DROP DATABASE fails and the instance is left half-removed.
            sudo -u postgres psql -tAc \
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db'" \
                >/dev/null 2>&1 || true
            if sudo -u postgres dropdb --if-exists "$db"; then
                log_success "Database '$db' dropped."
            else
                log_error "Could not drop database '$db' — remove it by hand."
            fi
        done <<< "$DATABASES"
    fi

    if [ "$HAS_ROLE" = true ]; then
        # The pg_shdepend check above is predictive; this is PostgreSQL's own
        # verdict and the one that counts. Stop here rather than continue —
        # deleting the Unix account while its PostgreSQL role survives leaves an
        # orphaned owner nobody will think to look for.
        if sudo -u postgres dropuser --if-exists "$OE_USER"; then
            log_success "PostgreSQL role '$OE_USER' dropped."
        else
            echo ""
            log_error "DROP ROLE '$OE_USER' failed — see the PostgreSQL error above."
            log_error "Stopping here. The account and $OE_HOME are untouched."
            echo ""
            log_error "Already removed: service, Nginx site, cron, and the databases"
            log_error "listed in the plan. Reassign what the role still owns:"
            log_error "  sudo -u postgres psql -d <database> \\"
            log_error "    -c 'REASSIGN OWNED BY \"$OE_USER\" TO postgres' \\"
            log_error "    -c 'DROP OWNED BY \"$OE_USER\"'"
            log_error "then re-run: $0 -u $OE_USER -n"
            exit 1
        fi
    fi
fi

if [ "$HAS_LOGROTATE" = true ]; then
    rm -f "/etc/logrotate.d/${OE_USER}-odoo"
    log_success "Logrotate rule removed."
fi

rm -f "$STATE_DIR/${OE_USER}.checkpoint" "$STATE_DIR/${OE_USER}.answers"
rm -f "/tmp/odoo_setup_checkpoint_${OE_USER}"
log_success "Installer state removed."

if command -v ufw >/dev/null 2>&1 && [ -f "$OE_HOME/${OE_USER}-odoo.conf" ]; then
    OE_PORT="$(awk -F'[ =]+' '/^(http_port|xmlrpc_port)/{print $2; exit}' \
        "$OE_HOME/${OE_USER}-odoo.conf" 2>/dev/null || true)"
    if [ -n "$OE_PORT" ]; then
        ufw delete allow "$OE_PORT/tcp" >/dev/null 2>&1 && \
            log_success "UFW rule for port $OE_PORT removed." || true
    fi
fi

# userdel -r takes the home directory, filestore and mail spool with it. Done
# last so a failure anywhere above still leaves the data on disk.
pkill -u "$OE_USER" 2>/dev/null || true
if userdel -r "$OE_USER" 2>/dev/null; then
    log_success "User '$OE_USER' and $OE_HOME removed."
else
    log_warn "userdel failed. Removing the home directory directly."
    userdel "$OE_USER" 2>/dev/null || true
    rm -rf "${OE_HOME:?}"
    log_success "$OE_HOME removed."
fi

# ==============================================================================
# Summary
# ==============================================================================

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            Instance Removed                              ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} Instance:  $OE_USER"
if [ "$KEEP_DATABASES" = true ]; then
echo -e "${GREEN}║${NC} Databases: ${YELLOW}kept (-k)${NC}"
elif [ "$SKIP_BACKUP" = false ] && [ -n "$DATABASES" ]; then
echo -e "${GREEN}║${NC} Backup:    ${BLUE}$SAFE_DIR${NC}"
echo -e "${GREEN}║${NC}            Restore with click-odoo-restoredb — see README"
else
echo -e "${GREEN}║${NC} Backup:    ${RED}none${NC}"
fi
if [ -n "$NGINX_SITES" ]; then
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC} TLS certificates were left in place. To remove them:"
for s in $NGINX_SITES; do
echo -e "${GREEN}║${NC}   ${YELLOW}sudo certbot delete --cert-name $s${NC}"
done
fi
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
