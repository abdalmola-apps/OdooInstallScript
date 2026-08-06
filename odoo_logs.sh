#!/bin/bash

# ==============================================================================
# Odoo Log Layout Script
#
# Reports where each instance on this server keeps its logs, and moves the ones
# still writing into the data directory over to /home/<user>/logs — where the
# installer puts them now, and what the weekly logrotate rule globs.
#
# Instances installed before that layout keep odoo-server.log next to the
# filestore under a rule that names that one file, so backup.log grows forever
# and the filestore shares a directory with something that rotates. This is the
# one-time fix. It also sets the Nginx and PostgreSQL rules to weekly, which is
# what a current install does at step 21.
#
# Nothing moves without -m. The move itself is a rename within /home/<user>, so
# a running Odoo keeps writing to the same inode and needs no restart.
#
# Usage:
#   sudo ./odoo_logs.sh [-u <username>] [-m]
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

OE_USER=""
MIGRATE=false

log_info()    { echo -e "${BLUE}[INFO $(date '+%H:%M:%S')]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN $(date '+%H:%M:%S')]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR $(date '+%H:%M:%S')]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK   $(date '+%H:%M:%S')]${NC} $*"; }

validate_username() {
    [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

usage() {
    cat <<EOF
Odoo Log Layout Script v${SCRIPT_VERSION}

Usage: sudo $0 [OPTIONS]

Options:
  -u <username>    Only this instance. Default: every instance on the server.
  -m               Migrate: move the logs, repoint the config, rewrite the
                   logrotate rule and the backup cron redirect.
  -h               Show this help message

Without -m nothing is touched — it only reports, and exits non-zero if any
instance still needs migrating, so it works as a check.

Logs belong in /home/<user>/logs so one rule can rotate the directory weekly
and the filestore in /home/<user>/data stays out of it. An instance whose
logfile points somewhere else entirely is treated as deliberate and left alone.

Examples:
  # What does this server look like?
  sudo $0

  # Move every old instance over
  sudo $0 -m

  # Just this one
  sudo $0 -u odoo18 -m
EOF
    exit 0
}

while getopts ":u:mh" opt; do
    case "$opt" in
        u) OE_USER="$OPTARG" ;;
        m) MIGRATE=true ;;
        h) usage ;;
        :) log_error "Option -$OPTARG requires an argument."; exit 1 ;;
        *) log_error "Unknown option: -$OPTARG"; usage ;;
    esac
done

# ==============================================================================
# Validation
# ==============================================================================

# Root: instance configs are 640 owned by their own user, and the logrotate
# rules and root's crontab are root's.
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)."
    exit 1
fi

if [ -n "$OE_USER" ] && ! validate_username "$OE_USER"; then
    log_error "Invalid username: '$OE_USER'"
    exit 1
fi

# ==============================================================================
# Helpers
# ==============================================================================

# Instances are the users owning a <user>-odoo.conf in their own home. Matching
# the path back exactly is what stops a stray file from inventing an instance.
discover_instances() {
    local conf u
    for conf in /home/*/*-odoo.conf; do
        [ -f "$conf" ] || continue
        u="$(basename "$conf")"; u="${u%-odoo.conf}"
        [ "$conf" = "/home/$u/$u-odoo.conf" ] || continue
        printf '%s\n' "$u"
    done
}

# First uncommented `key = value` in an Odoo config.
conf_value() {
    awk -F'[[:space:]]*=[[:space:]]*' -v k="$2" \
        '$0 !~ /^[[:space:]]*[;#]/ && $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {print $2; exit}' \
        "$1" 2>/dev/null | tr -d '[:space:]'
}

# Device number, so a move that would cross a filesystem can be spotted before
# it turns into copy-and-unlink under a process holding the file open.
dev_of() { stat -c %d "$1" 2>/dev/null || echo "?"; }

write_logrotate() {
    local u="$1" dir="$2"
    cat > "/etc/logrotate.d/${u}-odoo" <<CONF
$dir/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su $u $u
}
CONF
}

if [ -n "$OE_USER" ]; then
    if [ ! -f "/home/$OE_USER/${OE_USER}-odoo.conf" ]; then
        log_error "No Odoo config at /home/$OE_USER/${OE_USER}-odoo.conf"
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
# Report, and migrate when asked
# ==============================================================================

PENDING=0
MOVED=0
FAILED=0

echo ""
echo -e "${BLUE}Odoo logs${NC}  ${DIM}$(date '+%Y-%m-%d %H:%M')  ·  $(hostname)${NC}"

for u in "${INSTANCES[@]}"; do
    CONF="/home/$u/${u}-odoo.conf"
    WANT_DIR="/home/$u/logs"
    OLD_DIR="/home/$u/data"
    CUR_LOG="$(conf_value "$CONF" 'logfile')"

    echo ""
    echo -e "${BLUE}━━ $u${NC}"

    if [ -z "$CUR_LOG" ]; then
        echo -e "    ${DIM}·${NC} no logfile in the config — Odoo logs to the journal"
        echo -e "      ${DIM}journalctl -u ${u}-odoo.service -f${NC}"
        continue
    fi

    CUR_DIR="$(dirname "$CUR_LOG")"

    if [ "$CUR_DIR" = "$WANT_DIR" ]; then
        echo -e "    ${GREEN}✓${NC} $WANT_DIR"
        # Rewrite the rule anyway: an instance can be in the right place under
        # an old rule that names one file instead of globbing the directory.
        if [ "$MIGRATE" = true ]; then
            mkdir -p "$WANT_DIR"; chown "$u:$u" "$WANT_DIR"
            write_logrotate "$u" "$WANT_DIR"
        fi
    elif [ "$CUR_DIR" != "$OLD_DIR" ]; then
        echo -e "    ${DIM}·${NC} $CUR_DIR — not the default location, left alone"
        continue
    elif [ "$MIGRATE" != true ]; then
        echo -e "    ${YELLOW}!${NC} $CUR_DIR — logs sit in the data directory"
        echo -e "      ${DIM}migrate with: sudo abo logs -u $u -m${NC}"
        PENDING=$((PENDING + 1))
        continue
    else
        log_info "$u: moving logs from $CUR_DIR to $WANT_DIR..."
        mkdir -p "$WANT_DIR"
        chown "$u:$u" "$WANT_DIR"

        # A rename keeps an open file descriptor pointing at the same inode, so
        # a running Odoo follows the file across without a restart. That only
        # holds within one filesystem; across a mount boundary the move becomes
        # copy-and-unlink and Odoo would write into a deleted inode until it is
        # restarted. Refuse rather than lose the logs quietly.
        if [ "$(dev_of "$CUR_DIR")" != "$(dev_of "$WANT_DIR")" ]; then
            log_error "$CUR_DIR and $WANT_DIR are on different filesystems."
            log_error "Stop ${u}-odoo.service, move the logs by hand, then re-run."
            FAILED=$((FAILED + 1))
            continue
        fi

        # maxdepth 1 so the filestore below data/ is never in scope; *.log.*
        # picks up whatever the old rule already rotated.
        COUNT=0
        while IFS= read -r f; do
            mv -f "$f" "$WANT_DIR/"
            COUNT=$((COUNT + 1))
        done < <(find "$CUR_DIR" -maxdepth 1 -type f \
                     \( -name '*.log' -o -name '*.log.*' \) 2>/dev/null)
        chown -R "$u:$u" "$WANT_DIR"

        # sed -i writes a new file and renames it over the old one; re-assert
        # the config's mode and owner rather than trust that to carry.
        sed -i "s|^logfile[[:space:]]*=.*|logfile = $WANT_DIR/odoo-server.log|" "$CONF"
        chown "$u:$u" "$CONF"
        chmod 640 "$CONF"

        write_logrotate "$u" "$WANT_DIR"

        # The backup cron lives in root's crontab and redirects into the old
        # path. Rewrite only that redirect, on this instance's line.
        if crontab -l 2>/dev/null | grep -qF "$OLD_DIR/backup.log"; then
            crontab -l 2>/dev/null \
                | sed "s|$OLD_DIR/backup.log|$WANT_DIR/backup.log|g" \
                | crontab -
            log_success "$u: backup cron redirect updated."
        fi

        log_success "$u: $COUNT file(s) moved, config and logrotate rule updated."
        MOVED=$((MOVED + 1))
    fi

    # Current state, whichever branch got us here.
    for f in "$WANT_DIR"/*.log; do
        [ -f "$f" ] || continue
        echo -e "      ${DIM}$(du -h "$f" | cut -f1)\t$(basename "$f")${NC}"
    done
done

# ==============================================================================
# Server-wide rules
# ==============================================================================

# Same edit as step 21 of the installer: Nginx ships daily, and its per-instance
# access/error logs are already inside the distro's /var/log/nginx/*.log glob,
# so this file is the only place to reach them. The interval is the one
# directive that is a bare keyword alone on its line, which makes the
# substitution unambiguous and re-running it a no-op.
echo ""
echo -e "${BLUE}━━ server${NC}"
for LR_CONF in /etc/logrotate.d/nginx /etc/logrotate.d/postgresql-common; do
    [ -f "$LR_CONF" ] || continue
    NAME="$(basename "$LR_CONF")"
    if ! grep -qE '^[[:space:]]*(hourly|daily|monthly|yearly)[[:space:]]*$' "$LR_CONF"; then
        echo -e "    ${GREEN}✓${NC} $NAME: weekly"
    elif [ "$MIGRATE" = true ]; then
        sed -i -E 's/^([[:space:]]*)(hourly|daily|monthly|yearly)[[:space:]]*$/\1weekly/' \
            "$LR_CONF"
        log_success "$NAME: rotation set to weekly."
    else
        echo -e "    ${YELLOW}!${NC} $NAME: not weekly"
        echo -e "      ${DIM}fix with: sudo abo logs -m${NC}"
        PENDING=$((PENDING + 1))
    fi
done

# ==============================================================================
# Summary
# ==============================================================================

echo ""
if [ "$FAILED" -gt 0 ]; then
    log_error "$FAILED instance(s) could not be migrated — see above."
    exit 1
fi

if [ "$MIGRATE" = true ]; then
    log_success "Done. $MOVED instance(s) migrated."
    log_info "Check the rules with: sudo logrotate -d /etc/logrotate.conf"
elif [ "$PENDING" -gt 0 ]; then
    log_warn "$PENDING item(s) still on the old layout. Re-run with -m to fix them."
    exit 1
else
    log_success "Everything already rotates weekly from its own directory."
fi
