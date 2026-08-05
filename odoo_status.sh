#!/bin/bash

# ==============================================================================
# Odoo Instance Status Script
#
# One screen per instance: is it running, is it actually listening, what version,
# how much data, how much disk is left, when it was last backed up, how long the
# certificate has.
#
# Everything here is a cheap query — no `du` over the filestore — so it is fast
# enough to run whenever you wonder. Exits non-zero if anything looks wrong, so
# it also works as a monitoring check.
#
# Usage:
#   sudo ./odoo_status.sh [-u <username>]
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
readonly DIM='\033[2m'
readonly NC='\033[0m'

# A backup older than this is stale — the nightly cron runs at most 24h apart,
# so two missed nights means something is broken.
readonly BACKUP_STALE_HOURS=48
readonly CERT_WARN_DAYS=21

OE_USER=""

log_error()   { echo -e "${RED}[ERROR $(date '+%H:%M:%S')]${NC} $*" >&2; }

validate_username() {
    [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

usage() {
    cat <<EOF
Odoo Instance Status Script v${SCRIPT_VERSION}

Usage: sudo $0 [-u <username>]

Options:
  -u <username>    Only this instance. Default: every instance on the server.
  -h               Show this help message

Exit status is non-zero when something needs attention — a stopped service, a
port nobody is listening on, a stale backup, an expiring certificate, a disk
nearly full. Suitable for a cron or monitoring check.

Examples:
  sudo $0
  sudo $0 -u odoo18
EOF
    exit 0
}

while getopts ":u:h" opt; do
    case "$opt" in
        u) OE_USER="$OPTARG" ;;
        h) usage ;;
        :) log_error "Option -$OPTARG requires an argument."; exit 1 ;;
        *) log_error "Unknown option: -$OPTARG"; usage ;;
    esac
done

# Root: instance configs are chmod 640, and the database sizes need `sudo -u
# postgres`.
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)."
    exit 1
fi

if [ -n "$OE_USER" ] && ! validate_username "$OE_USER"; then
    log_error "Invalid username: '$OE_USER'."
    exit 1
fi

# ==============================================================================
# Discovery
# ==============================================================================

# The config file names the instance, same convention everything else here uses.
# Matching the path back exactly rejects a stray file that happens to end in
# -odoo.conf.
discover_instances() {
    local conf u
    for conf in /home/*/*-odoo.conf; do
        [ -f "$conf" ] || continue
        u="$(basename "$conf")"
        u="${u%-odoo.conf}"
        [ "$conf" = "/home/$u/$u-odoo.conf" ] || continue
        printf '%s\n' "$u"
    done
}

INSTANCES=()
if [ -n "$OE_USER" ]; then
    if [ ! -f "/home/$OE_USER/${OE_USER}-odoo.conf" ]; then
        log_error "No Odoo config at /home/$OE_USER/${OE_USER}-odoo.conf."
        log_error "Not an instance installed by this toolkit."
        exit 1
    fi
    INSTANCES=("$OE_USER")
else
    mapfile -t INSTANCES < <(discover_instances)
    if [ ${#INSTANCES[@]} -eq 0 ]; then
        log_error "No Odoo instances found (looked for /home/*/*-odoo.conf)."
        exit 1
    fi
fi

# ==============================================================================
# Helpers
# ==============================================================================

conf_value() {
    awk -F'[[:space:]]*=[[:space:]]*' -v k="$2" \
        '$0 !~ /^[[:space:]]*[;#]/ && $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {print $2; exit}' \
        "$1" 2>/dev/null | tr -d '[:space:]'
}

# "3d 4h" / "12m" — systemd prints a timestamp, not a duration.
human_since() {
    local ts secs
    ts="$1"
    [ -n "$ts" ] && [ "$ts" != "n/a" ] || { echo "?"; return; }
    secs="$(date -d "$ts" +%s 2>/dev/null)" || { echo "?"; return; }
    secs=$(( $(date +%s) - secs ))
    if   [ "$secs" -lt 3600 ]  ; then echo "$(( secs / 60 ))m"
    elif [ "$secs" -lt 86400 ] ; then echo "$(( secs / 3600 ))h"
    else echo "$(( secs / 86400 ))d $(( (secs % 86400) / 3600 ))h"
    fi
}

cert_days_left() {
    local end epoch
    end="$(openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2)"
    [ -n "$end" ] || return 1
    epoch="$(date -d "$end" +%s 2>/dev/null)" || return 1
    echo $(( (epoch - $(date +%s)) / 86400 ))
}

# First server_name of the Nginx site holding this instance's upstream block.
site_domain() {
    local site
    [ -d /etc/nginx/sites-available ] || return 1
    site=$(grep -rlE "^[[:space:]]*upstream[[:space:]]+${1}_odoo[[:space:]]*\{" \
        /etc/nginx/sites-available/ 2>/dev/null | head -1) || true
    [ -n "$site" ] || return 1
    awk '/^[[:space:]]*server_name[[:space:]]/ {
             sub(/;.*/, ""); sub(/^[[:space:]]*server_name[[:space:]]+/, "");
             print $1; exit
         }' "$site"
}

ok()   { echo -e "    ${GREEN}✓${NC} $*"; }
warn() { echo -e "    ${YELLOW}!${NC} $*"; PROBLEMS=$((PROBLEMS + 1)); }
bad()  { echo -e "    ${RED}✗${NC} $*"; PROBLEMS=$((PROBLEMS + 1)); }
note() { echo -e "    ${DIM}·${NC} $*"; }

# ==============================================================================
# Report
# ==============================================================================

TOTAL_PROBLEMS=0

echo ""
echo -e "${BLUE}Odoo status${NC}  ${DIM}$(date '+%Y-%m-%d %H:%M')  ·  $(hostname)${NC}"

for u in "${INSTANCES[@]}"; do
    PROBLEMS=0
    CONF="/home/$u/${u}-odoo.conf"
    SERVICE="${u}-odoo.service"

    PORT="$(conf_value "$CONF" 'http_port')"
    [ -n "$PORT" ] || PORT="$(conf_value "$CONF" 'xmlrpc_port')"
    PORT="${PORT:-8069}"

    echo ""
    echo -e "${BLUE}━━ $u ${NC}${DIM}· port $PORT${NC}"

    # --- Service -------------------------------------------------------------
    STATE="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
    SINCE="$(human_since "$(systemctl show "$SERVICE" -p ActiveEnterTimestamp --value 2>/dev/null || true)")"

    # A service that is "active" but not listening is the failure worth naming:
    # systemctl reports the fork, not whether Odoo survived its own startup.
    LISTENING=false
    ss -Hltn "sport = :$PORT" 2>/dev/null | grep -q . && LISTENING=true

    if [ "$STATE" = "active" ] && [ "$LISTENING" = true ]; then
        ok "running for $SINCE, listening on $PORT"
    elif [ "$STATE" = "active" ]; then
        bad "service is active but NOTHING is listening on $PORT"
        note "journalctl -u $SERVICE -n 50"
    else
        bad "service is ${STATE:-not installed}"
        note "systemctl status $SERVICE --no-pager"
    fi

    # --- Version -------------------------------------------------------------
    if [ -d "/home/$u/odoo/.git" ]; then
        BRANCH="$(sudo -u "$u" git -C "/home/$u/odoo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
        COMMIT="$(sudo -u "$u" git -C "/home/$u/odoo" rev-parse --short HEAD 2>/dev/null || echo '?')"
        WORKERS="$(conf_value "$CONF" 'workers')"
        note "Odoo $BRANCH at $COMMIT  ·  ${WORKERS:-?} workers"
    fi

    # --- Databases -----------------------------------------------------------
    DBS="$(sudo -u postgres psql -tA -F'|' -c "
        SELECT datname, pg_size_pretty(pg_database_size(datname))
        FROM pg_database
        WHERE datdba = (SELECT oid FROM pg_roles WHERE rolname = '$u')
          AND datname NOT IN ('postgres', 'template0', 'template1')
        ORDER BY pg_database_size(datname) DESC;" 2>/dev/null)" || true

    if [ -n "$DBS" ]; then
        note "$(printf '%s\n' "$DBS" | wc -l) database(s): $(printf '%s\n' "$DBS" \
            | awk -F'|' '{printf "%s (%s)  ", $1, $2}')"
    else
        warn "no databases owned by the '$u' role"
    fi

    # --- Backups -------------------------------------------------------------
    BACKUP_DIR="/home/$u/backups"
    if [ -d "$BACKUP_DIR" ]; then
        LATEST="$(find "$BACKUP_DIR" -maxdepth 1 -name '*.zip' -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2-)"
        if [ -n "$LATEST" ]; then
            AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$LATEST") ) / 3600 ))
            SIZE="$(du -h "$LATEST" | cut -f1)"
            COUNT="$(find "$BACKUP_DIR" -maxdepth 1 -name '*.zip' | wc -l)"
            if [ "$AGE_H" -gt "$BACKUP_STALE_HOURS" ]; then
                warn "newest backup is ${AGE_H}h old ($SIZE, $COUNT kept)"
                note "crontab -l | grep odoo_backup   ·   tail /home/$u/data/backup.log"
            else
                ok "backed up ${AGE_H}h ago ($SIZE, $COUNT kept)"
            fi
        else
            warn "backup directory exists but holds no .zip"
        fi
    else
        note "no backups configured"
    fi

    # --- Certificate ---------------------------------------------------------
    # Just the headline number. `abo ssl` is the tool that checks whether the
    # certificate actually covers every name Nginx serves.
    if DOMAIN="$(site_domain "$u")" && [ -n "$DOMAIN" ]; then
        CHAIN="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        if [ -f "$CHAIN" ] && DAYS="$(cert_days_left "$CHAIN")"; then
            if [ "$DAYS" -lt 0 ]; then
                bad "$DOMAIN — certificate EXPIRED $(( -DAYS )) day(s) ago"
            elif [ "$DAYS" -le "$CERT_WARN_DAYS" ]; then
                warn "$DOMAIN — certificate expires in $DAYS day(s)"
            else
                ok "$DOMAIN — certificate valid $DAYS more day(s)"
            fi
        else
            warn "$DOMAIN is served over plain HTTP — no certificate"
            note "sudo abo nginx -u $u -d $DOMAIN -e <email>"
        fi
    else
        note "no Nginx site — reachable on port $PORT directly"
    fi

    TOTAL_PROBLEMS=$(( TOTAL_PROBLEMS + PROBLEMS ))
done

# ==============================================================================
# Server-wide
# ==============================================================================

PROBLEMS=0
echo ""
echo -e "${BLUE}━━ server${NC}"

DISK_PCT="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
DISK_AVAIL="$(df -h --output=avail / | tail -1 | tr -d ' ')"
if [ "$DISK_PCT" -ge 90 ]; then
    bad "disk ${DISK_PCT}% full, $DISK_AVAIL free on /"
elif [ "$DISK_PCT" -ge 80 ]; then
    warn "disk ${DISK_PCT}% full, $DISK_AVAIL free on /"
else
    ok "disk ${DISK_PCT}% full, $DISK_AVAIL free on /"
fi

read -r MEM_TOTAL MEM_USED <<< "$(free -m | awk '/^Mem:/ {print $2, $3}')"
read -r SWAP_TOTAL SWAP_USED <<< "$(free -m | awk '/^Swap:/ {print $2, $3}')"
if [ "$SWAP_TOTAL" -gt 0 ]; then
    note "RAM ${MEM_USED}/${MEM_TOTAL}MB  ·  swap ${SWAP_USED}/${SWAP_TOTAL}MB"
else
    note "RAM ${MEM_USED}/${MEM_TOTAL}MB  ·  no swap"
fi

if systemctl list-unit-files certbot.timer >/dev/null 2>&1 \
    && [ -d /etc/letsencrypt/live ]; then
    if systemctl is-enabled certbot.timer >/dev/null 2>&1; then
        ok "certbot.timer armed"
    else
        warn "certbot.timer is NOT enabled — certificates will expire silently"
        note "sudo abo ssl"
    fi
fi

TOTAL_PROBLEMS=$(( TOTAL_PROBLEMS + PROBLEMS ))

echo ""
if [ "$TOTAL_PROBLEMS" -eq 0 ]; then
    echo -e "${GREEN}All good.${NC}"
else
    echo -e "${YELLOW}${TOTAL_PROBLEMS} thing(s) need attention.${NC}"
    exit 1
fi
