#!/bin/bash

# ==============================================================================
# Odoo Production Installation Script
#
# Automates a full production-grade Odoo setup including:
# - System user & PostgreSQL user (no superuser)
# - Odoo source cloning & Python venv
# - Auto-detected wkhtmltopdf for Ubuntu codename + arch
# - Computed workers/memory limits based on CPU & RAM
# - Multiple custom addon repos
# - Logrotate, UFW firewall
# - Optional Nginx reverse proxy + SSL (delegates to odoo_nginx.sh)
# - Optional automated backups (delegates to odoo_backup.sh)
# - Optional swap file
#
# Supports resume via checkpoint system.
#
# Author: abdalmola
# License: LGPL-3
# ==============================================================================

set -euo pipefail

# ==============================================================================
# Section 1: Constants & Colors
# ==============================================================================

readonly SCRIPT_VERSION="2.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Companion scripts sit next to this one in a git checkout, and land on PATH as
# odoo-nginx / odoo-backup after `sudo make install`. Prints the resolved path,
# returns 1 if neither exists.
find_companion() {
    local file="$1" cmd="$2"
    if [ -f "$SCRIPT_DIR/$file" ]; then
        printf '%s\n' "$SCRIPT_DIR/$file"
    else
        command -v "$cmd" 2>/dev/null || return 1
    fi
}

# Same idea, prefix-relative: <prefix>/bin/odoo-install finds
# <prefix>/share/odoo-install/requirements.txt, under any PREFIX or DESTDIR.
find_data_file() {
    local file="$1" c
    for c in "$SCRIPT_DIR/$file" "$SCRIPT_DIR/../share/odoo-install/$file"; do
        if [ -f "$c" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# ==============================================================================
# Section 2: Utility Functions
# ==============================================================================

log_info()    { echo -e "${BLUE}[INFO $(date '+%H:%M:%S')]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN $(date '+%H:%M:%S')]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR $(date '+%H:%M:%S')]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK   $(date '+%H:%M:%S')]${NC} $*"; }

generate_password() {
    local len="${1:-24}"
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$len"
}

# apt wrapper — waits for the dpkg lock instead of dying (unattended-upgrades
# holds it for minutes on a freshly booted server) and never opens a prompt.
# DPkg::Lock::Timeout needs apt >= 1.9.11, i.e. Ubuntu 20.04+.
# `sudo env` rather than `sudo VAR=…` so env_reset in sudoers can't strip them.
apt_get() {
    sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
        apt-get -o DPkg::Lock::Timeout=600 \
                -o Dpkg::Options::=--force-confold \
                -o Dpkg::Options::=--force-confdef "$@"
}

# --- Validators ---

validate_username() {
    [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1024 && $1 <= 65535 ))
}

validate_version() {
    [[ "$1" =~ ^[0-9]+\.0$ ]]
}

validate_db_name() {
    [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]
}

validate_git_url() {
    [[ "$1" =~ ^https://.*\.git$ ]] || [[ "$1" =~ ^git@.*\.git$ ]] || [[ "$1" =~ ^https://.+ ]]
}

# --- Domain / DNS ---

# Filled in once, before the DNS gate. `hostname -I` alone misses the public
# address on cloud VMs behind 1:1 NAT (AWS/GCP/Azure) — which is most of them —
# so every domain would look mispointed.
PUBLIC_IP=""

server_ips() {
    { hostname -I | tr ' ' '\n'; printf '%s\n' "$PUBLIC_IP"; } | grep -v '^$' | sort -u
}

# 0 = resolves to this server, 1 = resolves somewhere else, 2 = no record.
# getent uses glibc, so no dnsutils dependency. Leaves the addresses it found in
# DNS_RESOLVED_IPS for the caller to print.
DNS_RESOLVED_IPS=""
check_domain_dns() {
    DNS_RESOLVED_IPS="$(getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u)"
    [ -n "$DNS_RESOLVED_IPS" ] || return 2
    comm -12 <(echo "$DNS_RESOLVED_IPS") <(server_ips) | grep -q . || return 1
}

# --- Odoo Versions ---

readonly ODOO_REPO="https://github.com/odoo/odoo"

# The newest release branches, most recent first. Empty output means the repo
# was unreachable — callers fall back to a built-in list.
list_odoo_versions() {
    git ls-remote --heads "$ODOO_REPO" 2>/dev/null \
        | grep -oE 'refs/heads/[0-9]+\.0$' \
        | sed 's|refs/heads/||' \
        | sort -Vr \
        | head -4
}

odoo_branch_exists() {
    git ls-remote --heads --exit-code "$ODOO_REPO" "refs/heads/$1" >/dev/null 2>&1
}

readonly ODOO_RAW="https://raw.githubusercontent.com/odoo/odoo"

system_python_version() {
    python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])'
}

# Lowest Python a branch will start on, read from Odoo's own declaration.
# Its location and spelling have both moved: release.py in 19.0+,
# __init__.py in 15.0-18.0, and a bare assert in 14.0 and older.
odoo_min_python() {
    local v="$1" f raw
    for f in "odoo/release.py" "odoo/__init__.py"; do
        raw="$(timeout 12 curl -sfL --max-time 10 "$ODOO_RAW/$v/$f" 2>/dev/null \
               | grep -oE '(MIN_PY_VERSION *=|sys\.version_info *>=?) *\([0-9]+, *[0-9]+\)' \
               | grep -oE '[0-9]+, *[0-9]+' | head -1 | tr -d ' ')" || true
        if [ -n "$raw" ]; then
            echo "${raw/,/.}"
            return 0
        fi
    done
    return 1
}

# Highest Python the branch's requirements.txt has pins for. Approximate — it
# is the newest interpreter Odoo bothered to write markers for, which is the
# practical ceiling: past it, pinned wheels stop existing and the pip step in
# step 6 fails compiling gevent and friends.
odoo_max_python() {
    timeout 12 curl -sfL --max-time 10 "$ODOO_RAW/$1/requirements.txt" 2>/dev/null \
        | grep -oE "python_version *[<>=!]+ *'[0-9]+\.[0-9]+'" \
        | grep -oE "[0-9]+\.[0-9]+" | sort -V | tail -1
}

# "a <= b" on dotted versions.
version_le() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

# --- Port Selection ---

# A port counts as taken if something is listening on it, or if another
# instance's config claims it. The config check matters: a stopped instance
# still owns its port, and it would collide the moment both are running.
port_in_use() {
    local p="$1"
    if ss -Hltn "sport = :$p" 2>/dev/null | grep -q .; then
        return 0
    fi
    # sudo because instance configs are chmod 640 and owned by their own user.
    if sudo grep -rqsE "^[[:space:]]*(http_port|xmlrpc_port|gevent_port|longpolling_port)[[:space:]]*=[[:space:]]*${p}[[:space:]]*$" /home/*/*-odoo.conf; then
        return 0
    fi
    return 1
}

# Odoo needs a pair — the HTTP port and the websocket port directly above it —
# so both halves have to be free. Steps by one rather than two: since each
# candidate is checked on both halves anyway, this finds the lowest free pair
# instead of skipping over usable ones.
find_free_port() {
    local p="${1:-8069}"
    while [ "$p" -lt 65535 ]; do
        if ! port_in_use "$p" && ! port_in_use "$((p + 1))"; then
            echo "$p"
            return 0
        fi
        p=$((p + 1))
    done
    return 1
}

# --- System Info ---

get_ubuntu_codename() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${VERSION_CODENAME:-unknown}"
    else
        echo "unknown"
    fi
}

get_total_ram_mb() {
    awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo
}

# Size of the filesystem the swap file would live on, in MB. / rather than a
# guess, because that is where /swapfile goes.
get_disk_total_mb() {
    df -BM --output=size / 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0
}

get_disk_avail_mb() {
    df -BM --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0
}

# A swap file big enough to matter but never big enough to fill the disk it
# shares with the database and the filestore: 10% of the filesystem is the
# ceiling, whatever the RAM says.
max_swap_mb() {
    echo $(( $(get_disk_total_mb) / 10 ))
}

default_swap_mb() {
    local want max
    want=$(get_total_ram_mb)
    [ "$want" -gt 4096 ] && want=4096
    max=$(max_swap_mb)
    [ "$want" -gt "$max" ] && want=$max
    echo "$want"
}

system_timezone() {
    timedatectl show -p Timezone --value 2>/dev/null \
        || cat /etc/timezone 2>/dev/null \
        || echo "UTC"
}

# timedatectl's own list where it works, the zoneinfo database otherwise — the
# list is empty in some containers and would reject every valid zone.
validate_timezone() {
    local tz="$1" list
    [[ "$tz" =~ ^[A-Za-z0-9+_/-]+$ ]] || return 1
    list="$(timedatectl list-timezones 2>/dev/null || true)"
    if [ -n "$list" ]; then
        printf '%s\n' "$list" | grep -qxF "$tz"
    else
        [ -f "/usr/share/zoneinfo/$tz" ]
    fi
}

get_cpu_cores() {
    nproc
}

# --- Checkpoint System ---

save_checkpoint() {
    echo "$1" | sudo tee "$CHECKPOINT_FILE" > /dev/null
}

get_last_checkpoint() {
    sudo cat "$CHECKPOINT_FILE" 2>/dev/null || echo "0"
}

# Answers are re-read on the next run so a resumed install does not ask all
# eleven questions again — a mistyped port or version on the second pass would
# silently disagree with what steps 1-N already built.
save_answers() {
    sudo tee "$ANSWERS_FILE" > /dev/null <<ANSWERS
OE_VERSION=$(printf '%q' "$OE_VERSION")
OE_PORT=$(printf '%q' "$OE_PORT")
OE_TIMEZONE=$(printf '%q' "$OE_TIMEZONE")
SWAP_SIZE_MB=$(printf '%q' "$SWAP_SIZE_MB")
INSTALL_NGINX=$(printf '%q' "$INSTALL_NGINX")
OE_DOMAIN=$(printf '%q' "$OE_DOMAIN")
CERTBOT_EMAIL=$(printf '%q' "$CERTBOT_EMAIL")
CUSTOM_ADDONS_INPUT=$(printf '%q' "$CUSTOM_ADDONS_INPUT")
SETUP_SWAP=$(printf '%q' "$SETUP_SWAP")
SETUP_BACKUP=$(printf '%q' "$SETUP_BACKUP")
BACKUP_FILESTORE=$(printf '%q' "$BACKUP_FILESTORE")
BACKUP_RETENTION=$(printf '%q' "$BACKUP_RETENTION")
BACKUP_HOUR=$(printf '%q' "$BACKUP_HOUR")
CREATE_DB=$(printf '%q' "$CREATE_DB")
DB_NAME=$(printf '%q' "$DB_NAME")
DB_MODE=$(printf '%q' "$DB_MODE")
DB_DEMO=$(printf '%q' "$DB_DEMO")
ANSWERS
    sudo chmod 600 "$ANSWERS_FILE"
}

step() {
    local step_num="$1"
    local step_desc="$2"
    CURRENT_STEP="$step_num"
    if [ "$LAST_CHECKPOINT" -lt "$step_num" ]; then
        echo ""
        log_info "=== Step $step_num: $step_desc ==="
        return 0
    else
        log_warn "Skipping Step $step_num: $step_desc (already completed)"
        return 1
    fi
}

# --- Trap / Cleanup ---

cleanup() {
    local exit_code=$?
    # Only for failures once the install is underway. Input validation and the
    # companion-script check print their own message; following it with
    # "failed at step unknown, resume from step 1" just muddies it.
    if [ $exit_code -ne 0 ] && [ "${CURRENT_STEP:-0}" -ge 1 ]; then
        echo ""
        log_error "Script failed at step ${CURRENT_STEP:-unknown} of 21 (exit code: $exit_code)"
        log_error "To resume: re-run this script, enter the same username"
        log_error "('${OE_USER:-<username>}'), and accept the saved answers when asked."
        log_error "It will skip the completed steps and continue from step ${CURRENT_STEP:-1}."
        log_error "State: ${CHECKPOINT_FILE:-N/A}"
    fi
}

trap cleanup ERR INT TERM

# ==============================================================================
# Section 3: Arguments
# ==============================================================================

usage() {
    cat <<EOF
Odoo Production Installation Script v${SCRIPT_VERSION}

Usage: sudo $0 [-u <username>] [-y] [-h]

Options:
  -u <username>   Odoo system user. Prompted for if omitted.
  -y              Express install: accept every default without asking and
                  skip the confirmation. Needs -u.
  -h              Show this help.

Express defaults: Odoo 18.0, first free port pair from 8069, no Nginx,
no custom addons, swap if RAM < 4GB, daily backups at 02:00 with filestore
and 30-day retention.

  # interactive
  sudo $0

  # one command, no questions
  sudo $0 -u odoo18 -y

For an unattended install with Nginx or custom addons, pre-write the answers
file instead — see "Unattended installs" in the README.
EOF
    exit 0
}

EXPRESS="no"
CLI_USER=""

while getopts ":u:yh" opt; do
    case "$opt" in
        u) CLI_USER="$OPTARG" ;;
        y) EXPRESS="yes" ;;
        h) usage ;;
        :) log_error "Option -$OPTARG requires an argument."; exit 1 ;;
        *) log_error "Unknown option: -$OPTARG"; usage ;;
    esac
done

if [ "$EXPRESS" = "yes" ] && [ -z "$CLI_USER" ]; then
    log_error "-y needs a username: $0 -u <username> -y"
    exit 1
fi

# ==============================================================================
# Section 3b: Input Collection & Validation
# ==============================================================================

echo -e "${BLUE}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         Odoo Production Installation Script v${SCRIPT_VERSION}       ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Fail here rather than 10 minutes in, and cache the sudo timestamp so the
# unattended part of the run never stops to ask for a password.
if ! sudo -v; then
    log_error "This script needs sudo privileges."
    exit 1
fi

# --- Username ---
if [ -n "$CLI_USER" ]; then
    if ! validate_username "$CLI_USER"; then
        log_error "Invalid username '$CLI_USER'. Letters, digits and underscores only."
        exit 1
    fi
    OE_USER="$CLI_USER"
    log_info "Username: $OE_USER"
else
    while true; do
        read -rp "Enter the Odoo system username: " OE_USER
        if [ -z "$OE_USER" ]; then
            log_error "Username cannot be empty."
        elif ! validate_username "$OE_USER"; then
            log_error "Invalid username. Use only letters, digits, and underscores (must start with letter or underscore)."
        else
            break
        fi
    done
fi

# --- Resume state ---
# Keyed on the username, so it has to come after that prompt. Root-only, and
# under /var/lib rather than /tmp for two reasons: /tmp is cleared on reboot,
# losing the resume point exactly when a crashed install is most likely to be
# rebooted; and the answers file is sourced as root, so a world-writable
# location would let any local user plant code that runs as root.
STATE_DIR="/var/lib/odoo-install"
sudo mkdir -p "$STATE_DIR"
sudo chmod 700 "$STATE_DIR"
CHECKPOINT_FILE="$STATE_DIR/${OE_USER}.checkpoint"
ANSWERS_FILE="$STATE_DIR/${OE_USER}.answers"

# Carry over a checkpoint written by an older version of this script.
LEGACY_CHECKPOINT="/tmp/odoo_setup_checkpoint_${OE_USER}"
if [ -f "$LEGACY_CHECKPOINT" ] && ! sudo test -f "$CHECKPOINT_FILE"; then
    sudo mv "$LEGACY_CHECKPOINT" "$CHECKPOINT_FILE"
    log_info "Moved existing checkpoint to $CHECKPOINT_FILE"
fi

REUSE_ANSWERS="no"
if sudo test -f "$ANSWERS_FILE"; then
    log_info "A previous run for '$OE_USER' stopped after step $(get_last_checkpoint) of 21."
    if [ "$EXPRESS" = "yes" ]; then
        REUSE_ANSWERS="yes"
        log_info "Express mode — reusing the saved answers."
    else
        read -rp "Reuse its answers and skip the questions? (yes/no) [yes]: " REUSE_ANSWERS
        REUSE_ANSWERS="${REUSE_ANSWERS:-yes}"
        REUSE_ANSWERS="${REUSE_ANSWERS,,}"
    fi
fi

if [ "$REUSE_ANSWERS" = "yes" ]; then
    # shellcheck disable=SC1090  # generated by save_answers, root-owned 600
    . <(sudo cat "$ANSWERS_FILE")
    log_success "Loaded saved answers. Review the summary below before confirming."

elif [ "$EXPRESS" = "yes" ]; then
    OE_VERSION="18.0"
    OE_PORT="$(find_free_port 8069 || echo 8069)"
    # Whatever the server is already set to — express changes nothing here.
    OE_TIMEZONE="$(system_timezone)"
    INSTALL_NGINX="no"
    OE_DOMAIN=""
    CERTBOT_EMAIL=""
    CUSTOM_ADDONS_INPUT=""
    SETUP_SWAP="no"
    SWAP_SIZE_MB=0
    if [ "$(get_total_ram_mb)" -lt 4096 ]; then
        SETUP_SWAP="yes"
        SWAP_SIZE_MB="$(default_swap_mb)"
        [ "$SWAP_SIZE_MB" -gt 0 ] || SETUP_SWAP="no"
    fi
    SETUP_BACKUP="yes"
    BACKUP_FILESTORE="yes"
    BACKUP_RETENTION=30
    BACKUP_HOUR="02:00"
    CREATE_DB="yes"
    DB_NAME="$OE_USER"
    DB_MODE="prod"
    DB_DEMO="no"
    log_success "Express mode: Odoo $OE_VERSION on port $OE_PORT, no Nginx, daily backups at $BACKUP_HOUR."

else

# --- Version ---
# Built from the branches that actually exist in odoo/odoo, so the menu cannot
# go stale as Odoo releases, and a typo is caught here instead of at step 4
# after three steps of system changes.
DEFAULT_VERSION="18.0"
NETWORK_OK="yes"
mapfile -t ODOO_VERSIONS < <(list_odoo_versions)

if [ ${#ODOO_VERSIONS[@]} -eq 0 ]; then
    NETWORK_OK="no"
    ODOO_VERSIONS=("19.0" "18.0" "17.0" "16.0")
    log_warn "Could not reach github.com — falling back to a built-in version list."
fi

SYS_PY="$(system_python_version)"
CODENAME_NOW="$(get_ubuntu_codename)"

echo ""
echo "Available Odoo versions   (this server: Ubuntu $CODENAME_NOW, Python $SYS_PY)"

# Probe the listed versions in parallel — four sequential round trips to
# GitHub is a noticeable stall on an interactive prompt.
PY_PROBE_DIR="$(mktemp -d)"
for i in "${!ODOO_VERSIONS[@]}"; do
    ( odoo_min_python "${ODOO_VERSIONS[$i]}" > "$PY_PROBE_DIR/$i" 2>/dev/null || true ) &
done
wait

NEWEST_OK=""
declare -A MIN_PY_CACHE=()
for i in "${!ODOO_VERSIONS[@]}"; do
    v="${ODOO_VERSIONS[$i]}"
    minpy="$(cat "$PY_PROBE_DIR/$i" 2>/dev/null || true)"
    MIN_PY_CACHE["$v"]="$minpy"
    note=""
    if [ -z "$minpy" ]; then
        note="requirement unknown"
    elif version_le "$minpy" "$SYS_PY"; then
        note="needs Python >= $minpy — OK here"
        [ -z "$NEWEST_OK" ] && NEWEST_OK="$v"
    else
        note="needs Python >= $minpy — NOT usable on this server"
    fi
    [ "$v" = "$DEFAULT_VERSION" ] && note="$note, default"
    printf "  %d) %-6s %s\n" "$((i + 1))" "$v" "($note)"
done
rm -rf "$PY_PROBE_DIR"

# If the usual default cannot run here, offer the newest one that can.
DEFAULT_MIN_PY="${MIN_PY_CACHE[$DEFAULT_VERSION]:-}"
if [ -n "$NEWEST_OK" ] && [ "$NEWEST_OK" != "$DEFAULT_VERSION" ] \
   && { [ -z "$DEFAULT_MIN_PY" ] || ! version_le "$DEFAULT_MIN_PY" "$SYS_PY"; }; then
    log_warn "Odoo $DEFAULT_VERSION cannot run on Python $SYS_PY — defaulting to $NEWEST_OK."
    DEFAULT_VERSION="$NEWEST_OK"
fi
echo ""

while true; do
    read -rp "Select a number, or type any version [$DEFAULT_VERSION]: " VERSION_CHOICE
    VERSION_CHOICE="${VERSION_CHOICE:-$DEFAULT_VERSION}"

    # A bare number picks from the menu; anything else is taken literally, so
    # versions older than the four listed are still reachable.
    if [[ "$VERSION_CHOICE" =~ ^[0-9]+$ ]] && [ "$VERSION_CHOICE" -ge 1 ] \
       && [ "$VERSION_CHOICE" -le "${#ODOO_VERSIONS[@]}" ]; then
        OE_VERSION="${ODOO_VERSIONS[$((VERSION_CHOICE - 1))]}"
    else
        OE_VERSION="$VERSION_CHOICE"
    fi

    if ! validate_version "$OE_VERSION"; then
        log_error "Invalid version format. Expected XX.0 (e.g. 18.0), or a number from the list."
        continue
    fi
    # Menu entries came from ls-remote, so only a typed version needs checking.
    if [ "$NETWORK_OK" = "yes" ] && ! printf '%s\n' "${ODOO_VERSIONS[@]}" | grep -qx "$OE_VERSION" \
       && ! odoo_branch_exists "$OE_VERSION"; then
        log_error "No branch '$OE_VERSION' in github.com/odoo/odoo."
        continue
    fi

    if [ "$NETWORK_OK" = "yes" ]; then
        SEL_MIN_PY="${MIN_PY_CACHE[$OE_VERSION]:-}"
        [ -z "$SEL_MIN_PY" ] && SEL_MIN_PY="$(odoo_min_python "$OE_VERSION" || true)"
        SEL_MAX_PY="$(odoo_max_python "$OE_VERSION" || true)"

        # Hard stop: Odoo asserts on this at import, so it cannot start at all.
        if [ -n "$SEL_MIN_PY" ] && ! version_le "$SEL_MIN_PY" "$SYS_PY"; then
            log_error "Odoo $OE_VERSION requires Python >= $SEL_MIN_PY, this server has $SYS_PY."
            log_error "Pick a newer Odoo, or install on a newer Ubuntu."
            continue
        fi

        # Soft stop: it would start, but step 6 has to build pinned wheels that
        # were never published for an interpreter this new.
        if [ -n "$SEL_MAX_PY" ] && ! version_le "$SYS_PY" "$SEL_MAX_PY"; then
            log_warn "Odoo $OE_VERSION predates Python $SYS_PY — its requirements only"
            log_warn "pin up to $SEL_MAX_PY, so installing dependencies will likely fail."
            log_warn "Ubuntu $CODENAME_NOW ships Python $SYS_PY. Odoo ${ODOO_VERSIONS[0]} is the safe choice here."
            read -rp "Use $OE_VERSION anyway? (yes/no) [no]: " FORCE_VER
            if [ "${FORCE_VER,,}" != "yes" ]; then
                continue
            fi
        fi
    fi

    log_info "Odoo version: $OE_VERSION"
    break
done

# --- Port ---
# Default to the first free pair rather than a fixed 8069, so a second instance
# on the same server just works. Entered ports are checked too — nothing
# validated this before, and a collision only surfaced as a service that
# refused to start after the install had reported success.
DEFAULT_PORT="$(find_free_port 8069 || echo 8069)"
if [ "$DEFAULT_PORT" != "8069" ]; then
    log_info "Port 8069 is already taken — suggesting $DEFAULT_PORT instead."
fi

while true; do
    read -rp "Enter the Odoo HTTP port [$DEFAULT_PORT]: " OE_PORT
    OE_PORT="${OE_PORT:-$DEFAULT_PORT}"
    if ! validate_port "$OE_PORT"; then
        log_error "Invalid port. Must be a number between 1024 and 65535."
    elif port_in_use "$OE_PORT"; then
        log_error "Port $OE_PORT is already in use. Free one: $DEFAULT_PORT."
    elif port_in_use "$((OE_PORT + 1))"; then
        log_error "Port $((OE_PORT + 1)) (websocket) is in use. Free pair starts at $DEFAULT_PORT."
    else
        break
    fi
done

# --- Nginx ---
while true; do
    read -rp "Install Nginx as reverse proxy? (yes/no) [no]: " INSTALL_NGINX
    INSTALL_NGINX="${INSTALL_NGINX:-no}"
    INSTALL_NGINX="${INSTALL_NGINX,,}" # lowercase
    if [[ "$INSTALL_NGINX" == "yes" || "$INSTALL_NGINX" == "no" ]]; then
        break
    fi
    log_error "Please answer 'yes' or 'no'."
done

# --- Domain & Email (required if Nginx — validated by odoo_nginx.sh) ---
OE_DOMAIN=""
CERTBOT_EMAIL=""
if [ "$INSTALL_NGINX" = "yes" ]; then
    read -rp "Enter the domain name (e.g., odoo.example.com): " OE_DOMAIN
    read -rp "Enter email for Let's Encrypt SSL certificate: " CERTBOT_EMAIL
fi

# --- Custom Addon Repos ---
read -rp "Enter custom addon Git URLs (comma-separated, or leave empty): " CUSTOM_ADDONS_INPUT

# --- Timezone ---
# The system timezone, not just Odoo's — logs, cron and the backup schedule all
# read it. Defaults to whatever the server already has, so the common answer is
# to press Enter and change nothing.
TZ_DEFAULT="$(system_timezone)"
while true; do
    read -rp "System timezone [$TZ_DEFAULT]: " OE_TIMEZONE
    OE_TIMEZONE="${OE_TIMEZONE:-$TZ_DEFAULT}"
    if validate_timezone "$OE_TIMEZONE"; then
        break
    fi
    log_error "Unknown timezone: '$OE_TIMEZONE'. Use a tz name like Europe/Berlin or UTC."
    log_error "List them with: timedatectl list-timezones"
done

# --- Swap ---
SWAP_DEFAULT="no"
if [ "$(get_total_ram_mb)" -lt 4096 ]; then
    SWAP_DEFAULT="yes"
    log_warn "Low RAM detected ($(get_total_ram_mb)MB). Swap is recommended."
fi

while true; do
    read -rp "Set up swap file? (yes/no) [$SWAP_DEFAULT]: " SETUP_SWAP
    SETUP_SWAP="${SETUP_SWAP:-$SWAP_DEFAULT}"
    SETUP_SWAP="${SETUP_SWAP,,}"
    if [[ "$SETUP_SWAP" == "yes" || "$SETUP_SWAP" == "no" ]]; then
        break
    fi
    log_error "Please answer 'yes' or 'no'."
done

# --- Swap Size ---
SWAP_SIZE_MB=0
if [ "$SETUP_SWAP" = "yes" ]; then
    SWAP_MAX_MB=$(max_swap_mb)
    SWAP_DEFAULT_MB=$(default_swap_mb)

    # A cap below 512MB means the disk is too small for swap to be worth the
    # space it would take from the database.
    if [ "$SWAP_MAX_MB" -lt 512 ]; then
        log_warn "The disk is only $(( $(get_disk_total_mb) / 1024 ))GB, so 10% of it is"
        log_warn "${SWAP_MAX_MB}MB — too small to be useful. Skipping swap."
        SETUP_SWAP="no"
    else
        echo ""
        echo "  RAM: $(get_total_ram_mb)MB   Disk: $(( $(get_disk_total_mb) / 1024 ))GB"
        echo "  Swap may be at most 10% of the disk: ${SWAP_MAX_MB}MB ($(( SWAP_MAX_MB / 1024 ))GB)"
        while true; do
            read -rp "Swap size in GB [$(( SWAP_DEFAULT_MB / 1024 ))]: " SWAP_INPUT
            if [ -z "$SWAP_INPUT" ]; then
                SWAP_SIZE_MB=$SWAP_DEFAULT_MB
                break
            fi
            if ! [[ "$SWAP_INPUT" =~ ^[0-9]+$ ]] || [ "$SWAP_INPUT" -eq 0 ]; then
                log_error "Enter a whole number of GB, 1 or more."
                continue
            fi
            SWAP_SIZE_MB=$(( SWAP_INPUT * 1024 ))
            if [ "$SWAP_SIZE_MB" -gt "$SWAP_MAX_MB" ]; then
                log_error "${SWAP_INPUT}GB is more than 10% of the disk (max ${SWAP_MAX_MB}MB)."
                continue
            fi
            break
        done
    fi
fi

# --- Automated Backups ---
while true; do
    read -rp "Set up automated daily backups? (yes/no) [yes]: " SETUP_BACKUP
    SETUP_BACKUP="${SETUP_BACKUP:-yes}"
    SETUP_BACKUP="${SETUP_BACKUP,,}"
    if [[ "$SETUP_BACKUP" == "yes" || "$SETUP_BACKUP" == "no" ]]; then
        break
    fi
    log_error "Please answer 'yes' or 'no'."
done

# --- Backup Options (if backups enabled) ---
BACKUP_RETENTION=30
BACKUP_FILESTORE="yes"
BACKUP_HOUR="02:00"
if [ "$SETUP_BACKUP" = "yes" ]; then
    while true; do
        read -rp "Include filestore in backups? (yes/no) [yes]: " BACKUP_FILESTORE
        BACKUP_FILESTORE="${BACKUP_FILESTORE:-yes}"
        BACKUP_FILESTORE="${BACKUP_FILESTORE,,}"
        if [[ "$BACKUP_FILESTORE" == "yes" || "$BACKUP_FILESTORE" == "no" ]]; then
            break
        fi
        log_error "Please answer 'yes' or 'no'."
    done

    while true; do
        read -rp "Backup retention in days [30]: " BACKUP_RETENTION
        BACKUP_RETENTION="${BACKUP_RETENTION:-30}"
        if [[ "$BACKUP_RETENTION" =~ ^[0-9]+$ ]] && [ "$BACKUP_RETENTION" -ge 1 ]; then
            break
        fi
        log_error "Must be a positive number."
    done

    while true; do
        read -rp "Backup time (HH:MM, 24h format) [02:00]: " BACKUP_HOUR
        BACKUP_HOUR="${BACKUP_HOUR:-02:00}"
        if [[ "$BACKUP_HOUR" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            break
        fi
        log_error "Invalid time format. Use HH:MM (e.g., 02:00, 23:30)."
    done
fi

# --- First Database ---
# The config sets list_db = False, so Odoo's database manager is hidden and
# there is no way to create the first database from the browser. Without this
# the install ends with a running server nobody can log into.
while true; do
    read -rp "Create the first database now? (yes/no) [yes]: " CREATE_DB
    CREATE_DB="${CREATE_DB:-yes}"
    CREATE_DB="${CREATE_DB,,}"
    if [[ "$CREATE_DB" == "yes" || "$CREATE_DB" == "no" ]]; then
        break
    fi
    log_error "Please answer 'yes' or 'no'."
done

DB_NAME=""
DB_MODE="prod"
DB_DEMO="no"
if [ "$CREATE_DB" = "yes" ]; then
    while true; do
        read -rp "Database name [$OE_USER]: " DB_NAME
        DB_NAME="${DB_NAME:-$OE_USER}"
        if validate_db_name "$DB_NAME"; then
            break
        fi
        log_error "Invalid name. Start with a letter; letters, digits and underscores only."
    done

    while true; do
        read -rp "Is this database production or demo? (prod/demo) [prod]: " DB_MODE
        DB_MODE="${DB_MODE:-prod}"
        DB_MODE="${DB_MODE,,}"
        if [[ "$DB_MODE" == "prod" || "$DB_MODE" == "demo" ]]; then
            break
        fi
        log_error "Please answer 'prod' or 'demo'."
    done

    if [ "$DB_MODE" = "demo" ]; then
        while true; do
            read -rp "Load Odoo demo data? (yes/no) [yes]: " DB_DEMO
            DB_DEMO="${DB_DEMO:-yes}"
            DB_DEMO="${DB_DEMO,,}"
            if [[ "$DB_DEMO" == "yes" || "$DB_DEMO" == "no" ]]; then
                break
            fi
            log_error "Please answer 'yes' or 'no'."
        done
    else
        # Production never gets demo data — it is close to impossible to remove
        # cleanly once installed.
        DB_DEMO="no"
    fi
fi

fi # end of the prompt block skipped when reusing saved answers

# An answers file written before these two existed has neither, and this runs on
# all three input paths — so fill them in here rather than inside the prompts.
OE_TIMEZONE="${OE_TIMEZONE:-$(system_timezone)}"
# Re-validated here because a hand-written answers file is a documented way to
# run unattended, and this value reaches both `timedatectl set-timezone` and a
# psql string literal. A typo would otherwise surface as a failure at step 2,
# after the prompts are long past.
if ! validate_timezone "$OE_TIMEZONE"; then
    log_error "Invalid timezone '$OE_TIMEZONE' in the saved answers."
    log_error "Fix OE_TIMEZONE in $ANSWERS_FILE, or delete the file to start over."
    exit 1
fi
SWAP_SIZE_MB="${SWAP_SIZE_MB:-0}"
if [ "$SETUP_SWAP" = "yes" ] && [ "$SWAP_SIZE_MB" -eq 0 ]; then
    SWAP_SIZE_MB="$(default_swap_mb)"
    [ "$SWAP_SIZE_MB" -ge 512 ] || SETUP_SWAP="no"
fi

# --- DNS gate -----------------------------------------------------------------
# On every input path, and before anything is installed. Certbot cannot issue a
# certificate for a domain that does not resolve to this server, and Let's
# Encrypt rate-limits failed validations to 5 per hostname per hour — so two
# careless retries cost an hour. Catching it here also means a fresh run, not a
# half-installed one, when the fix is "add an A record and wait 5 minutes".
# Unconditional: the DNS gate needs it, and so does the final summary, which
# otherwise prints a literal "<server-ip>" placeholder for a no-Nginx install.
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"

while [ "$INSTALL_NGINX" = "yes" ]; do
    check_domain_dns "$OE_DOMAIN" && dns_rc=0 || dns_rc=$?

    if [ "$dns_rc" -eq 0 ]; then
        log_success "DNS OK — $OE_DOMAIN points to this server."
        break
    fi

    echo ""
    if [ "$dns_rc" -eq 2 ]; then
        log_warn "$OE_DOMAIN has no DNS record — it does not resolve at all."
    else
        log_warn "$OE_DOMAIN resolves to: $(echo "$DNS_RESOLVED_IPS" | tr '\n' ' ')"
        log_warn "None of those is this server: $(server_ips | tr '\n' ' ')"
    fi

    cat <<EOF

  Add this record at your DNS provider, then choose [r]:

      Type   A
      Name   $OE_DOMAIN
      Value  ${PUBLIC_IP:-<the public IP of this server>}
      TTL    300  (or the lowest offered)

  At TTL 300 it is usually live in under 5 minutes. Check it yourself with:
      getent ahosts $OE_DOMAIN

  Behind Cloudflare's proxy (orange cloud), a load balancer or NAT the
  addresses are meant to differ — that case is [c].

EOF
    # No tty (piped install) means no answer is coming — carry on rather than
    # dying on EOF with nothing installed and nothing explaining why.
    read -rp "  [r] re-check  [d] different domain  [c] continue anyway  [s] skip Nginx: " dns_choice \
        || dns_choice="c"
    case "${dns_choice,,}" in
        d) read -rp "  Domain: " OE_DOMAIN ;;
        c) log_warn "Continuing. If certbot fails, the site stays on plain HTTP."
           break ;;
        s) INSTALL_NGINX="no"
           OE_DOMAIN=""
           CERTBOT_EMAIL=""
           log_info "Nginx and SSL skipped — Odoo will answer on port $OE_PORT directly."
           break ;;
        *) : ;; # r, or Enter: loop and re-check the same domain
    esac
done

# Runs either way: on a reused run these come from the answers file, and the
# addon list is stored as the raw input string rather than a serialised array.
RAM_MB=$(get_total_ram_mb)
IFS=',' read -ra CUSTOM_ADDONS_GIT_URLS <<< "$CUSTOM_ADDONS_INPUT"

VALID_ADDON_URLS=()
for url in "${CUSTOM_ADDONS_GIT_URLS[@]}"; do
    url="$(echo "$url" | xargs)" # trim whitespace
    [ -z "$url" ] && continue
    if ! validate_git_url "$url"; then
        log_error "Invalid Git URL: $url"
        log_error "Expected format: https://github.com/user/repo or git@github.com:user/repo.git"
        exit 1
    fi
    VALID_ADDON_URLS+=("$url")
done

# ==============================================================================
# Derived Variables
# ==============================================================================

OE_HOME="/home/$OE_USER"
OE_HOME_EXT="$OE_HOME/odoo"
OE_CONFIG="${OE_USER}-odoo.conf"
OE_SERVICE="${OE_USER}-odoo.service"
OE_DATA_DIR="$OE_HOME/data"
# Logs get their own directory so logrotate can take the whole thing with one
# glob — the data dir holds the filestore and sessions, which must never rotate.
OE_LOG_DIR="$OE_HOME/logs"
OE_CUSTOM_ADDONS_DIR="$OE_HOME/custom-addons"
OE_LONGPOLLING_PORT=$((OE_PORT + 1))

# Odoo 16 renamed longpolling_port -> gevent_port. Writing the wrong key means
# Odoo keeps its default 8072 while Nginx proxies /websocket to OE_PORT+1 —
# websockets silently break.
if [ "${OE_VERSION%%.*}" -ge 16 ]; then
    GEVENT_KEY="gevent_port"
else
    GEVENT_KEY="longpolling_port"
fi

# Reuse the existing password on a resumed or repeat run, otherwise the final
# summary prints a password that is not the one in the config file.
if [ -f "$OE_HOME/$OE_CONFIG" ] && sudo grep -q '^admin_passwd' "$OE_HOME/$OE_CONFIG"; then
    ADMIN_PASSWD="$(sudo awk -F'[ =]+' '/^admin_passwd/{print $2; exit}' "$OE_HOME/$OE_CONFIG")"
    log_warn "Existing config found — reusing its admin password."
else
    ADMIN_PASSWD="$(generate_password 24)"
fi

# Addons path is built here, not inside step 10: a run that dies during step 11
# resumes with checkpoint=10, which skips step 10 and would leave this unset —
# `set -u` then kills the resumed run.
ADDONS_PATH="$OE_HOME_EXT/addons"
if [ ${#VALID_ADDON_URLS[@]} -gt 0 ]; then
    for url in "${VALID_ADDON_URLS[@]}"; do
        ADDONS_PATH="$ADDONS_PATH,$OE_CUSTOM_ADDONS_DIR/$(basename "$url" .git)"
    done
else
    ADDONS_PATH="$ADDONS_PATH,$OE_CUSTOM_ADDONS_DIR"
fi

# Odoo does not recurse into addons_path entries. A repo that groups its modules
# into subdirectories (accounting/, hr/, l10n/) needs one entry per subdirectory
# — without it those modules are invisible, and any that were already installed
# load as "not installable, skipped": their models vanish while their views and
# crons stay in the database, which breaks the web client at runtime.
# Called after cloning (step 10), so the directories actually exist.
expand_addon_collections() {
    local out="" entry sub
    local IFS=,
    for entry in $1; do
        out="${out:+$out,}$entry"
        [ -d "$entry" ] || continue
        for sub in "$entry"/*/; do
            sub="${sub%/}"
            # already a module — covered by its parent entry
            [ -f "$sub/__manifest__.py" ] && continue
            # a directory of modules — needs its own entry
            if compgen -G "$sub/*/__manifest__.py" > /dev/null 2>&1; then
                out="$out,$sub"
            fi
        done
    done
    printf '%s' "$out"
}

LAST_CHECKPOINT=$(get_last_checkpoint)
CURRENT_STEP=0

# Compute workers & memory limits
CPU_CORES=$(get_cpu_cores)
WORKERS=$(( CPU_CORES * 2 + 1 ))
MAX_WORKERS_BY_RAM=$(( RAM_MB / 256 ))
if [ "$WORKERS" -gt "$MAX_WORKERS_BY_RAM" ]; then
    WORKERS="$MAX_WORKERS_BY_RAM"
fi
if [ "$WORKERS" -lt 2 ]; then
    WORKERS=2
fi

MAX_CRON_THREADS=1
LIMIT_MEMORY_SOFT=$(( (RAM_MB * 1024 * 1024 * 8 / 10) / (WORKERS + MAX_CRON_THREADS + 1) ))
LIMIT_MEMORY_HARD=$(( LIMIT_MEMORY_SOFT * 12 / 10 ))
DB_MAXCONN=$(( WORKERS * 2 + 4 ))

# ==============================================================================
# Companion Script Check
# ==============================================================================

# Fail now, not at step 15. Downloading odoo_install.sh on its own is an easy
# mistake to make, and the alternative is discovering it after fourteen steps
# of system changes have already been applied.
MISSING_SCRIPTS=()
if [ "$INSTALL_NGINX" = "yes" ] && ! find_companion odoo_nginx.sh odoo-nginx >/dev/null; then
    MISSING_SCRIPTS+=("odoo_nginx.sh — required for the Nginx + SSL step")
fi
if [ "$SETUP_BACKUP" = "yes" ] && ! find_companion odoo_backup.sh odoo-backup >/dev/null; then
    MISSING_SCRIPTS+=("odoo_backup.sh — required for automated backups")
fi

if [ ${#MISSING_SCRIPTS[@]} -gt 0 ]; then
    echo ""
    log_error "Missing companion script(s) — not in $SCRIPT_DIR, not on PATH:"
    for m in "${MISSING_SCRIPTS[@]}"; do
        log_error "  - $m"
    done
    log_error ""
    log_error "Download the whole repository rather than a single file:"
    log_error "  git clone https://github.com/abdalmola-apps/OdooInstallScript.git"
    log_error "  cd OdooInstallScript && sudo ./odoo_install.sh"
    log_error ""
    log_error "Or answer 'no' to that feature to install without it."
    exit 1
fi

# ==============================================================================
# Confirmation Summary
# ==============================================================================

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                  Installation Summary                   ║${NC}"
echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║${NC} Username:        $OE_USER"
echo -e "${BLUE}║${NC} Odoo Version:    $OE_VERSION"
echo -e "${BLUE}║${NC} HTTP Port:       $OE_PORT"
echo -e "${BLUE}║${NC} Longpolling:     $OE_LONGPOLLING_PORT"
echo -e "${BLUE}║${NC} Workers:         $WORKERS (CPU: $CPU_CORES, RAM: ${RAM_MB}MB)"
echo -e "${BLUE}║${NC} Nginx + SSL:     $INSTALL_NGINX"
if [ "$INSTALL_NGINX" = "yes" ]; then
echo -e "${BLUE}║${NC} Domain:          $OE_DOMAIN"
echo -e "${BLUE}║${NC} Certbot Email:   $CERTBOT_EMAIL"
fi
echo -e "${BLUE}║${NC} Addon Repos:     ${#VALID_ADDON_URLS[@]}"
echo -e "${BLUE}║${NC} Timezone:        $OE_TIMEZONE"
if [ "$SETUP_SWAP" = "yes" ]; then
echo -e "${BLUE}║${NC} Swap:            yes (${SWAP_SIZE_MB}MB)"
else
echo -e "${BLUE}║${NC} Swap:            no"
fi
echo -e "${BLUE}║${NC} Daily Backups:   $SETUP_BACKUP"
if [ "$SETUP_BACKUP" = "yes" ]; then
echo -e "${BLUE}║${NC}   Filestore:     $BACKUP_FILESTORE"
echo -e "${BLUE}║${NC}   Retention:     ${BACKUP_RETENTION} days"
echo -e "${BLUE}║${NC}   Schedule:      Daily at $BACKUP_HOUR"
fi
echo -e "${BLUE}║${NC} First Database:  $CREATE_DB"
if [ "$CREATE_DB" = "yes" ]; then
echo -e "${BLUE}║${NC}   Name:          $DB_NAME"
echo -e "${BLUE}║${NC}   Type:          $DB_MODE (demo data: $DB_DEMO)"
fi
echo -e "${BLUE}║${NC} Home Dir:        $OE_HOME"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ "$EXPRESS" = "yes" ]; then
    log_info "Express mode — proceeding without confirmation."
else
    read -rp "Proceed with installation? (yes/no): " CONFIRM
    CONFIRM="${CONFIRM,,}"
    if [ "$CONFIRM" != "yes" ]; then
        log_warn "Installation cancelled by user."
        exit 0
    fi
fi

# Persist before touching anything, so an interruption during step 1 still
# leaves a resumable run.
save_answers

echo ""
log_info "Starting installation..."

# ==============================================================================
# Section 4: Steps 1-3 — System Setup
# ==============================================================================

# Step 1: Check & Install PostgreSQL
if step 1 "Check & Install PostgreSQL"; then
    if ! command -v psql &> /dev/null; then
        log_info "PostgreSQL not found. Installing..."
        apt_get update -qq
        apt_get install -y postgresql postgresql-contrib
    else
        log_success "PostgreSQL is already installed."
    fi
    save_checkpoint 1
fi

# Step 2: Set Timezone
if step 2 "Set System Timezone"; then
    if [ "$(system_timezone)" = "$OE_TIMEZONE" ]; then
        log_success "System timezone is already $OE_TIMEZONE."
    else
        sudo timedatectl set-timezone "$OE_TIMEZONE"
        log_success "System timezone set to $OE_TIMEZONE."
    fi
    save_checkpoint 2
fi

# Step 3: Create System User & PostgreSQL User
if step 3 "Create System User & PostgreSQL User"; then
    # System group
    if ! getent group "$OE_USER" >/dev/null; then
        log_info "Creating system group '$OE_USER'..."
        sudo addgroup --system "$OE_USER"
    fi

    # System user
    if ! id -u "$OE_USER" >/dev/null 2>&1; then
        log_info "Creating system user '$OE_USER'..."
        sudo adduser --system --shell=/bin/bash --gecos "Odoo user" \
            --disabled-password --home "$OE_HOME" --ingroup "$OE_USER" "$OE_USER"
        sudo usermod -L "$OE_USER"
    else
        log_success "System user '$OE_USER' already exists."
        sudo usermod -a -G "$OE_USER" "$OE_USER" 2>/dev/null || true
    fi

    # PostgreSQL user — no superuser for security
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$OE_USER'" | grep -q 1; then
        log_success "PostgreSQL user '$OE_USER' already exists."
    else
        log_info "Creating PostgreSQL user '$OE_USER' (no superuser)..."
        sudo -u postgres createuser --createdb --no-superuser --no-createrole "$OE_USER"
    fi

    # Set timezone for PostgreSQL user
    sudo -u postgres psql -c "ALTER USER \"$OE_USER\" SET TIMEZONE = '$OE_TIMEZONE';"
    log_success "PostgreSQL user configured."
    save_checkpoint 3
fi

# ==============================================================================
# Section 5: Steps 4-7 — Odoo & Dependencies
# ==============================================================================

# Step 4: Clone Odoo Source
if step 4 "Clone Odoo Source Code"; then
    if [ -d "$OE_HOME_EXT" ]; then
        log_success "Odoo directory already exists at $OE_HOME_EXT. Skipping."
    else
        log_info "Cloning Odoo $OE_VERSION..."
        sudo git clone --depth 1 --branch "$OE_VERSION" \
            "https://www.github.com/odoo/odoo" "$OE_HOME_EXT"
        sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME_EXT"
        log_success "Odoo $OE_VERSION cloned."
    fi
    save_checkpoint 4
fi

# Step 5: System Dependencies & wkhtmltopdf
if step 5 "Install System Dependencies & wkhtmltopdf"; then
    log_info "Updating package lists (waits for the dpkg lock if held)..."
    apt_get update -qq

    log_info "Installing system dependencies..."
    apt_get install -y \
        git python3-cffi build-essential wget curl \
        python3-dev python3-venv python3-wheel python3-setuptools \
        libxslt-dev libzip-dev libldap2-dev libsasl2-dev \
        libpng-dev libjpeg-dev libpq-dev

    # wkhtmltopdf release + build to use, per Ubuntu codename. Upstream archived
    # the project in 2023, so the asset list is now fixed and these are the only
    # combinations that exist (checked against the GitHub release assets):
    #   focal  - only 0.12.6-1 ships focal amd64/arm64; later releases are ppc64el only
    #   jammy  - 0.12.6.1-3, the last release
    #   noble  - no noble build exists or ever will. The jammy deb installs anyway:
    #            it needs libssl3 and libpng16-16, which noble's libssl3t64 and
    #            libpng16-16t64 Provide, and libjpeg-turbo8 is still itself there.
    # The old code built <version>.<codename>_<arch>.deb for all three, so focal
    # and noble always 404'd — wget exited 8 and killed the run at step 5.
    CODENAME="$(get_ubuntu_codename)"
    ARCH="$(dpkg --print-architecture)"

    case "$CODENAME" in
        focal) WKHTMLTOPDF_VERSION="0.12.6-1";   WKHTMLTOPDF_DIST="focal" ;;
        jammy) WKHTMLTOPDF_VERSION="0.12.6.1-3"; WKHTMLTOPDF_DIST="jammy" ;;
        noble) WKHTMLTOPDF_VERSION="0.12.6.1-3"; WKHTMLTOPDF_DIST="jammy" ;;
        *)
            WKHTMLTOPDF_VERSION="0.12.6.1-3"; WKHTMLTOPDF_DIST="jammy"
            log_warn "Unknown Ubuntu codename '$CODENAME'. Trying the jammy build."
            ;;
    esac

    WKHTMLTOPDF_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/wkhtmltox_${WKHTMLTOPDF_VERSION}.${WKHTMLTOPDF_DIST}_${ARCH}.deb"

    if command -v wkhtmltopdf &> /dev/null; then
        log_success "wkhtmltopdf is already installed."
        # The apt build uses an unpatched Qt that ignores --header-html/--footer-html,
        # so Odoo reports render without headers and footers.
        if ! wkhtmltopdf --version 2>/dev/null | grep -q 'patched qt'; then
            log_warn "This wkhtmltopdf is NOT the patched-Qt build — Odoo report"
            log_warn "headers and footers will not render. Remove it and re-run:"
            log_warn "  sudo apt-get remove -y wkhtmltopdf"
        fi
    else
        log_info "Downloading wkhtmltopdf ${WKHTMLTOPDF_VERSION} (${WKHTMLTOPDF_DIST} build) for ${CODENAME}/${ARCH}..."
        WKHTMLTOPDF_DEB="/tmp/wkhtmltox_${WKHTMLTOPDF_VERSION}.deb"
        # Report the URL on failure — a bare `wget -q` exit 8 says nothing about
        # which asset was missing.
        if ! wget -q "$WKHTMLTOPDF_URL" -O "$WKHTMLTOPDF_DEB"; then
            rm -f "$WKHTMLTOPDF_DEB"
            log_error "Download failed: $WKHTMLTOPDF_URL"
            log_error "No wkhtmltopdf build exists for ${CODENAME}/${ARCH}."
            log_error "Available assets: https://github.com/wkhtmltopdf/packaging/releases"
            exit 1
        fi
        apt_get install -y "$WKHTMLTOPDF_DEB"
        rm -f "$WKHTMLTOPDF_DEB"
        log_success "wkhtmltopdf installed."
    fi

    save_checkpoint 5
fi

# Step 6: Python Virtual Environment & Dependencies
if step 6 "Create Virtual Environment & Install Python Dependencies"; then
    if [ ! -d "$OE_HOME_EXT/venv" ]; then
        log_info "Creating Python virtual environment..."
        sudo -u "$OE_USER" python3 -m venv "$OE_HOME_EXT/venv"
    else
        log_success "Virtual environment already exists."
    fi

    log_info "Installing Python packages from Odoo requirements..."
    sudo -u "$OE_USER" "$OE_HOME_EXT/venv/bin/pip" install --no-cache-dir \
        -r "$OE_HOME_EXT/requirements.txt"

    log_info "Installing additional Python packages..."
    sudo -u "$OE_USER" "$OE_HOME_EXT/venv/bin/pip" install --no-cache-dir \
        num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL

    # Extra requirements, from the checkout or from <prefix>/share/odoo-install.
    # pip runs as $OE_USER, so the file has to be readable by that user — a
    # checkout under /root (mode 700) is not. Stage a copy inside $OE_HOME.
    if REQUIREMENTS_FILE="$(find_data_file requirements.txt)"; then
        log_info "Installing extra requirements from $REQUIREMENTS_FILE..."
        EXTRA_REQ="$OE_HOME/.extra-requirements.txt"
        sudo install -m 644 -o "$OE_USER" "$REQUIREMENTS_FILE" "$EXTRA_REQ"
        sudo -u "$OE_USER" "$OE_HOME_EXT/venv/bin/pip" install --no-cache-dir \
            -r "$EXTRA_REQ"
        sudo rm -f "$EXTRA_REQ"
    fi

    log_success "Python dependencies installed."
    save_checkpoint 6
fi

# Step 7: Node.js — LESS & rtlcss
if step 7 "Install LESS & rtlcss"; then
    log_info "Installing Node.js and npm..."
    apt_get install -y nodejs npm

    log_info "Installing LESS and rtlcss globally..."
    sudo npm install -g less less-plugin-clean-css rtlcss
    log_success "Node.js dependencies installed."
    save_checkpoint 7
fi

# ==============================================================================
# Section 6: Steps 8-10 — Directories & Repos
# ==============================================================================

# Step 8: Create Directories
if step 8 "Create Odoo Directories"; then
    log_info "Creating data, logs and custom-addons directories..."
    sudo mkdir -p "$OE_DATA_DIR" "$OE_LOG_DIR" "$OE_CUSTOM_ADDONS_DIR"
    sudo chown -R "$OE_USER:$OE_USER" "$OE_DATA_DIR" "$OE_LOG_DIR" "$OE_CUSTOM_ADDONS_DIR"
    log_success "Directories created."
    save_checkpoint 8
fi

# Step 9: SSH Key Generation
if step 9 "Generate SSH Key"; then
    SSH_DIR="$OE_HOME/.ssh"
    if [ ! -d "$SSH_DIR" ]; then
        log_info "Generating SSH key for '$OE_USER'..."
        sudo mkdir -p "$SSH_DIR"
        sudo chown "$OE_USER:$OE_USER" "$SSH_DIR"
        sudo chmod 700 "$SSH_DIR"
        sudo -u "$OE_USER" ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519" -N "" -q
        log_success "SSH key generated at $SSH_DIR/id_ed25519"
        echo ""
        log_info "Public key (add to your Git hosting):"
        sudo cat "$SSH_DIR/id_ed25519.pub"
        echo ""
    else
        log_success "SSH directory already exists. Skipping key generation."
    fi
    save_checkpoint 9
fi

# Step 10: Clone Custom Addon Repos
if step 10 "Clone Custom Addon Repos"; then
    for url in "${VALID_ADDON_URLS[@]:-}"; do
        [ -z "$url" ] && continue
        REPO_PATH="$OE_CUSTOM_ADDONS_DIR/$(basename "$url" .git)"

        if [ -d "$REPO_PATH" ]; then
            log_success "Addon repo '$(basename "$REPO_PATH")' already exists. Skipping."
            continue
        fi

        log_info "Cloning addon repo: $url ..."
        # -H so git finds the key generated in step 9; accept-new so an unknown
        # host key does not hang the run waiting on a yes/no prompt.
        sudo -u "$OE_USER" -H env GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' \
            git clone "$url" "$REPO_PATH" || {
            log_warn "Failed to clone $url — trying with sudo..."
            sudo git clone "$url" "$REPO_PATH"
            sudo chown -R "$OE_USER:$OE_USER" "$REPO_PATH"
        }
    done

    log_success "Addon repos configured. Addons path: $ADDONS_PATH"
    save_checkpoint 10
fi

# ==============================================================================
# Section 7: Steps 11-12 — Config & Service
# ==============================================================================

# Step 11: Odoo Configuration File
if step 11 "Create Odoo Configuration File"; then
    ADDONS_PATH="$(expand_addon_collections "$ADDONS_PATH")"
    log_info "Writing config to $OE_HOME/$OE_CONFIG..."
    log_info "Addons path: $ADDONS_PATH"
    sudo tee "$OE_HOME/$OE_CONFIG" > /dev/null <<ODOO_CONF
[options]
admin_passwd = $ADMIN_PASSWD
db_host = False
db_port = False
db_user = $OE_USER
db_password = False
http_port = $OE_PORT
$GEVENT_KEY = $OE_LONGPOLLING_PORT

addons_path = $ADDONS_PATH
data_dir = $OE_DATA_DIR
logfile = $OE_LOG_DIR/odoo-server.log

; Performance tuning (auto-computed: CPU=$CPU_CORES, RAM=${RAM_MB}MB)
workers = $WORKERS
max_cron_threads = $MAX_CRON_THREADS
limit_memory_soft = $LIMIT_MEMORY_SOFT
limit_memory_hard = $LIMIT_MEMORY_HARD
limit_time_cpu = 600
limit_time_real = 1200
db_maxconn = $DB_MAXCONN

; Security (proxy_mode set by odoo_nginx.sh if Nginx is enabled)
proxy_mode = False
list_db = False
ODOO_CONF

    # Secure the config file — readable only by odoo user and root
    sudo chown "$OE_USER:$OE_USER" "$OE_HOME/$OE_CONFIG"
    sudo chmod 640 "$OE_HOME/$OE_CONFIG"

    log_success "Configuration file created with secure permissions (640)."
    save_checkpoint 11
fi

# Step 12: Systemd Service File
if step 12 "Create Systemd Service File"; then
    log_info "Writing service file to /etc/systemd/system/$OE_SERVICE..."
    sudo tee "/etc/systemd/system/$OE_SERVICE" > /dev/null <<SERVICE_CONF
[Unit]
Description=Odoo $OE_VERSION ($OE_USER)
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
SyslogIdentifier=$OE_USER-odoo
User=$OE_USER
Group=$OE_USER

Environment=XDG_RUNTIME_DIR=/tmp/runtime-$OE_USER
# Only the V8 flags on Node's allow-list work here; --optimize-for-size and
# --no-opt make node refuse to start at all, which breaks rtlcss (RTL assets).
Environment="NODE_OPTIONS=--max-old-space-size=256"

ExecStart=$OE_HOME_EXT/venv/bin/python3 $OE_HOME_EXT/odoo-bin -c $OE_HOME/$OE_CONFIG
WorkingDirectory=$OE_HOME_EXT

StandardOutput=journal+console
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SERVICE_CONF

    sudo chmod 644 "/etc/systemd/system/$OE_SERVICE"
    sudo chown root:root "/etc/systemd/system/$OE_SERVICE"

    log_success "Systemd service file created."
    save_checkpoint 12
fi

# ==============================================================================
# Section 8: Steps 13-16 — Permissions, Logrotate, Nginx (via script), Firewall
# ==============================================================================

# Step 13: Set Ownership & Permissions
if step 13 "Set Ownership & Permissions"; then
    log_info "Setting directory ownership..."
    sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME_EXT"
    sudo chown -R "$OE_USER:$OE_USER" "$OE_DATA_DIR"
    sudo chown -R "$OE_USER:$OE_USER" "$OE_LOG_DIR"
    sudo chown -R "$OE_USER:$OE_USER" "$OE_CUSTOM_ADDONS_DIR"
    log_success "Permissions set."
    save_checkpoint 13
fi

# Step 14: Logrotate
if step 14 "Configure Logrotate"; then
    log_info "Creating logrotate config for Odoo logs..."
    # Also created in step 8; repeated here so a resume that starts past step 8
    # still has somewhere for the glob to point.
    sudo mkdir -p "$OE_LOG_DIR"
    sudo chown "$OE_USER:$OE_USER" "$OE_LOG_DIR"
    # The whole directory, so backup.log rotates on the same schedule without a
    # second rule. copytruncate because Odoo holds the file open and does not
    # reopen on a signal.
    sudo tee "/etc/logrotate.d/${OE_USER}-odoo" > /dev/null <<LOGROTATE_CONF
$OE_LOG_DIR/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su $OE_USER $OE_USER
}
LOGROTATE_CONF

    log_success "Logrotate configured for $OE_LOG_DIR (weekly, 12 rotations)."
    save_checkpoint 14
fi

# Step 15: Nginx + Let's Encrypt SSL (conditional — delegates to odoo_nginx.sh)
if step 15 "Configure Nginx & SSL"; then
    if [ "$INSTALL_NGINX" = "yes" ]; then
        if ! NGINX_SCRIPT="$(find_companion odoo_nginx.sh odoo-nginx)"; then
            log_error "odoo_nginx.sh not found next to this script, and odoo-nginx"
            log_error "is not on PATH. Keep the scripts together, or run 'sudo make install'."
            exit 1
        fi

        log_info "Running odoo_nginx.sh..."
        # -y: the DNS gate above already asked. Without it the sub-script would
        # ask the same question a second time.
        sudo bash "$NGINX_SCRIPT" \
            -u "$OE_USER" \
            -d "$OE_DOMAIN" \
            -e "$CERTBOT_EMAIL" \
            -p "$OE_PORT" \
            -l "$OE_LONGPOLLING_PORT" \
            -y

        log_success "Nginx configured via odoo_nginx.sh."
    else
        log_info "Nginx installation skipped (not selected)."
    fi
    save_checkpoint 15
fi

# Step 16: UFW Firewall
if step 16 "Configure UFW Firewall"; then
    log_info "Configuring UFW firewall..."
    apt_get install -y ufw

    # Allow the port sshd actually listens on — hardcoding 22 locks you out of
    # any server running SSH elsewhere, and the OpenSSH profile only covers 22.
    SSH_PORT="$(sudo sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
    log_info "Allowing SSH on port ${SSH_PORT:-22}."
    sudo ufw allow "${SSH_PORT:-22}/tcp"
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp

    # Only allow direct Odoo port if Nginx is NOT installed
    if [ "$INSTALL_NGINX" != "yes" ]; then
        sudo ufw allow "$OE_PORT/tcp"
        log_info "Allowed direct access on port $OE_PORT (no Nginx)."
    fi

    sudo ufw --force enable
    log_success "UFW firewall enabled."
    save_checkpoint 16
fi

# ==============================================================================
# Section 9: Steps 17-19 — Swap, Service Start & Backups
# ==============================================================================

# Step 17: Swap File (conditional)
if step 17 "Set Up Swap File"; then
    if [ "$SETUP_SWAP" = "yes" ]; then
        if swapon --show | grep -q '/swapfile'; then
            log_success "Swap file already exists. Skipping."
        else
            # Size was chosen and capped at 10% of the disk during the prompts.
            # Re-check free space here: fallocate would fail on a disk that has
            # filled up since, leaving a partial /swapfile behind.
            AVAIL_MB=$(get_disk_avail_mb)
            if [ "$AVAIL_MB" -lt $(( SWAP_SIZE_MB + 512 )) ]; then
                log_error "Only ${AVAIL_MB}MB free on / — not enough for a ${SWAP_SIZE_MB}MB swap file."
                log_error "Free some space and re-run, or install without swap."
                exit 1
            fi

            log_info "Creating ${SWAP_SIZE_MB}MB swap file..."
            if ! sudo fallocate -l "${SWAP_SIZE_MB}M" /swapfile; then
                sudo rm -f /swapfile
                log_error "Could not allocate the swap file."
                exit 1
            fi
            sudo chmod 600 /swapfile
            sudo mkswap /swapfile
            sudo swapon /swapfile

            # Add to fstab if not already there
            if ! grep -q '/swapfile' /etc/fstab; then
                echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
            fi

            log_success "Swap file created (${SWAP_SIZE_MB}MB)."
        fi
    else
        log_info "Swap setup skipped (not selected)."
    fi
    save_checkpoint 17
fi

# Step 18: Start Odoo Service
if step 18 "Start Odoo Service"; then
    log_info "Reloading systemd and starting Odoo service..."
    sudo systemctl daemon-reload
    sudo systemctl enable "$OE_SERVICE"
    sudo systemctl start "$OE_SERVICE"

    # `systemctl start` returns as soon as the process is forked, so it exits 0
    # for an Odoo that dies a second later on a bad config or a busy port. Wait
    # for the port to actually accept — otherwise the only symptom is "site
    # can't be reached" long after the installer claimed success.
    # Socket check only — port_in_use() also counts a config-file claim, and
    # step 11 just wrote a config claiming this port, so it would always pass.
    odoo_listening() { ss -Hltn "sport = :$OE_PORT" 2>/dev/null | grep -q .; }

    for _ in $(seq 1 60); do
        odoo_listening && break
        sleep 1
    done

    if odoo_listening; then
        log_success "Odoo service started and enabled, listening on port $OE_PORT."
    else
        log_error "Odoo is NOT listening on port $OE_PORT after 60s."
        log_error "The rest of the install will continue, but the site will not load."
        log_error "  sudo systemctl status $OE_SERVICE --no-pager"
        log_error "  sudo tail -50 $OE_LOG_DIR/odoo-server.log"
    fi
    save_checkpoint 18
fi

# Step 19: Automated Backups (conditional — delegates to odoo_backup.sh)
if step 19 "Set Up Automated Backups"; then
    if [ "$SETUP_BACKUP" = "yes" ]; then
        if ! BACKUP_SCRIPT="$(find_companion odoo_backup.sh odoo-backup)"; then
            log_error "odoo_backup.sh not found next to this script, and odoo-backup"
            log_error "is not on PATH. Keep the scripts together, or run 'sudo make install'."
            log_warn "Skipping backup cron setup. You can set it up manually later."
            SETUP_BACKUP="no"
        fi

        if [ "$SETUP_BACKUP" = "yes" ]; then
            # Copy script to user home for cron to use
            BACKUP_SCRIPT_DST="$OE_HOME/odoo_backup.sh"
            sudo cp "$BACKUP_SCRIPT" "$BACKUP_SCRIPT_DST"
            sudo chown "$OE_USER:$OE_USER" "$BACKUP_SCRIPT_DST"
            sudo chmod 750 "$BACKUP_SCRIPT_DST"

            # Create backup directory
            sudo mkdir -p "$OE_HOME/backups"
            sudo chown "$OE_USER:$OE_USER" "$OE_HOME/backups"

            # Build backup flags from user options
            BACKUP_FLAGS="-u $OE_USER -r $BACKUP_RETENTION -q"
            if [ "$BACKUP_FILESTORE" = "yes" ]; then
                BACKUP_FLAGS="$BACKUP_FLAGS -f"
            fi

            # Parse HH:MM into cron hour and minute
            CRON_HOUR="${BACKUP_HOUR%%:*}"
            CRON_MIN="${BACKUP_HOUR##*:}"

            # cron is standard on Ubuntu Server but absent from minimal cloud
            # and container images, and an installed-but-stopped cron service
            # would leave the job silently never running.
            if ! command -v crontab &> /dev/null; then
                log_info "Installing cron..."
                apt_get install -y cron
            fi
            sudo systemctl enable --now cron >/dev/null 2>&1 || \
                log_warn "Could not enable the cron service — check 'systemctl status cron'."

            # Install cron job
            CRON_LINE="$CRON_MIN $CRON_HOUR * * * $BACKUP_SCRIPT_DST $BACKUP_FLAGS >> $OE_LOG_DIR/backup.log 2>&1"

            # `|| true` covers both empty cases, either of which used to abort
            # the whole run with a bare exit 1 under `set -e` + pipefail:
            # root having no crontab at all (every fresh server), and grep -v
            # filtering out the only line there is (every re-run).
            { sudo crontab -l 2>/dev/null | grep -vF "$BACKUP_SCRIPT_DST" || true
              echo "$CRON_LINE"; } | sudo crontab -

            # Read it back — `crontab -` reports nothing useful on a rejected file.
            if sudo crontab -l 2>/dev/null | grep -qF "$BACKUP_SCRIPT_DST"; then
                log_success "Backup cron job installed (daily at $BACKUP_HOUR)."
                log_info "Cron entry: $CRON_LINE"
                log_info "Backup directory: $OE_HOME/backups"
            else
                log_error "Cron job did not install. Add it manually with 'sudo crontab -e':"
                log_error "  $CRON_LINE"
            fi
        fi
    else
        log_info "Automated backups skipped (not selected)."
    fi
    save_checkpoint 19
fi

# Step 20: Create the First Database
# Appended rather than inserted: step numbers are persisted in the checkpoint
# file, so renumbering would corrupt resume for in-flight installs.
ADMIN_USER_PASSWD=""
if step 20 "Create First Database"; then
    if [ "$CREATE_DB" = "yes" ]; then
        if sudo -u postgres psql -tAc \
             "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1; then
            log_success "Database '$DB_NAME' already exists. Skipping creation."
        else
            DEMO_ARGS=()
            if [ "$DB_DEMO" != "yes" ]; then
                DEMO_ARGS=(--without-demo=all)
            fi

            log_info "Creating '$DB_NAME' ($DB_MODE, demo data: $DB_DEMO). This takes a few minutes..."
            # --no-http because the service from step 18 already holds the port,
            # --workers=0 so this init runs in one process.
            sudo -u "$OE_USER" -H "$OE_HOME_EXT/venv/bin/python3" "$OE_HOME_EXT/odoo-bin" \
                -c "$OE_HOME/$OE_CONFIG" -d "$DB_NAME" -i base "${DEMO_ARGS[@]}" \
                --workers=0 --no-http --stop-after-init --log-level=warn

            # Odoo ships admin/admin. Replace it before anything is reachable.
            # odoo-bin shell execs piped stdin, then rolls back — hence commit().
            ADMIN_USER_PASSWD="$(generate_password 16)"
            if printf "env.ref('base.user_admin').write({'password': '%s'})\nenv.cr.commit()\n" \
                 "$ADMIN_USER_PASSWD" \
               | sudo -u "$OE_USER" -H "$OE_HOME_EXT/venv/bin/python3" "$OE_HOME_EXT/odoo-bin" \
                     shell -c "$OE_HOME/$OE_CONFIG" -d "$DB_NAME" --no-http --log-level=warn \
                     > /dev/null 2>&1; then
                log_success "Database '$DB_NAME' created; admin password set."
            else
                ADMIN_USER_PASSWD=""
                log_warn "Database created, but setting the admin password failed."
                log_warn "The admin login is still admin/admin — change it at first login."
            fi
        fi
    else
        log_info "First database skipped (not selected)."
    fi
    save_checkpoint 20
fi

# Step 21: Weekly rotation for the logs this install does not own.
# Appended at the end: step numbers are a persisted resume interface.
if step 21 "Set Nginx & PostgreSQL Logs to Weekly Rotation"; then
    # Odoo's own logs are handled by step 14. These two files belong to their
    # packages — Nginx ships daily/rotate 14, postgresql-common ships weekly —
    # and the per-instance Nginx logs (${OE_USER}-odoo-*.log) fall under the
    # distro's /var/log/nginx/*.log glob, so editing that file in place is the
    # only way to reach them without a duplicate-entry error from logrotate.
    #
    # The interval is the only directive that is a bare keyword on its own line,
    # so the substitution is unambiguous and re-running it is a no-op. Note that
    # apt will offer the usual conffile prompt on the next package upgrade.
    for LR_CONF in /etc/logrotate.d/nginx /etc/logrotate.d/postgresql-common; do
        [ -f "$LR_CONF" ] || continue
        if sudo grep -qE '^[[:space:]]*(hourly|daily|monthly|yearly)[[:space:]]*$' "$LR_CONF"; then
            sudo sed -i -E 's/^([[:space:]]*)(hourly|daily|monthly|yearly)[[:space:]]*$/\1weekly/' \
                "$LR_CONF"
            log_success "$(basename "$LR_CONF"): rotation set to weekly."
        else
            log_success "$(basename "$LR_CONF"): already weekly."
        fi
    done
    save_checkpoint 21
fi

# ==============================================================================
# Section 10: Final Summary
# ==============================================================================

# Build access URL. Nginx being installed does not mean SSL succeeded — certbot
# fails whenever DNS is not pointing here yet — and printing https:// when
# nothing listens on 443 is exactly the "site can't be reached" the user gets.
if [ "$INSTALL_NGINX" = "yes" ] && sudo test -d "/etc/letsencrypt/live/$OE_DOMAIN"; then
    ACCESS_URL="https://$OE_DOMAIN"
elif [ "$INSTALL_NGINX" = "yes" ]; then
    ACCESS_URL="http://$OE_DOMAIN  (no certificate — see below)"
else
    ACCESS_URL="http://${PUBLIC_IP:-<server-ip>}:$OE_PORT"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            Installation Complete!                       ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} Odoo User:       ${BLUE}$OE_USER${NC}"
echo -e "${GREEN}║${NC} Odoo Version:    ${BLUE}$OE_VERSION${NC}"
echo -e "${GREEN}║${NC} Access URL:      ${BLUE}$ACCESS_URL${NC}"
if [ "$INSTALL_NGINX" = "yes" ] && ! sudo test -d "/etc/letsencrypt/live/$OE_DOMAIN"; then
echo -e "${GREEN}║${NC}   ${YELLOW}Certbot did not issue a certificate — port 443 is closed.${NC}"
echo -e "${GREEN}║${NC}   Point $OE_DOMAIN at ${PUBLIC_IP:-this server}, then run:"
echo -e "${GREEN}║${NC}   ${YELLOW}sudo certbot --nginx -d $OE_DOMAIN -m $CERTBOT_EMAIL --redirect${NC}"
fi
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC} Master Password: ${RED}$ADMIN_PASSWD${NC}"
echo -e "${GREEN}║${NC}   (database management only — not a login)"
if [ "$CREATE_DB" = "yes" ]; then
echo -e "${GREEN}║${NC} Database:        $DB_NAME ($DB_MODE, demo data: $DB_DEMO)"
if [ -n "$ADMIN_USER_PASSWD" ]; then
echo -e "${GREEN}║${NC} Login:           ${BLUE}admin${NC} / ${RED}$ADMIN_USER_PASSWD${NC}"
else
echo -e "${GREEN}║${NC} Login:           ${BLUE}admin${NC} / set on an earlier run (or still admin)"
fi
else
echo -e "${GREEN}║${NC} Database:        ${YELLOW}none created${NC}"
echo -e "${GREEN}║${NC}   list_db = False hides the database manager, so create one with:"
echo -e "${GREEN}║${NC}   ${YELLOW}sudo -u $OE_USER $OE_HOME_EXT/venv/bin/python3 $OE_HOME_EXT/odoo-bin \\${NC}"
echo -e "${GREEN}║${NC}   ${YELLOW}  -c $OE_HOME/$OE_CONFIG -d <name> -i base --without-demo=all \\${NC}"
echo -e "${GREEN}║${NC}   ${YELLOW}  --workers=0 --no-http --stop-after-init${NC}"
fi
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC} Config File:     $OE_HOME/$OE_CONFIG"
echo -e "${GREEN}║${NC} Logs:            $OE_LOG_DIR/  (logrotate: weekly, 12 kept)"
echo -e "${GREEN}║${NC} Workers:         $WORKERS"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC} Service Commands:"
echo -e "${GREEN}║${NC}   Start:    ${YELLOW}sudo systemctl start $OE_SERVICE${NC}"
echo -e "${GREEN}║${NC}   Stop:     ${YELLOW}sudo systemctl stop $OE_SERVICE${NC}"
echo -e "${GREEN}║${NC}   Restart:  ${YELLOW}sudo systemctl restart $OE_SERVICE${NC}"
echo -e "${GREEN}║${NC}   Status:   ${YELLOW}sudo systemctl status $OE_SERVICE${NC}"
echo -e "${GREEN}║${NC}   Logs:     ${YELLOW}sudo journalctl -u $OE_SERVICE -f${NC}"
echo -e "${GREEN}║${NC}"
if [ "$INSTALL_NGINX" = "yes" ]; then
echo -e "${GREEN}║${NC} Nginx:           ${GREEN}Enabled${NC} ($OE_DOMAIN)"
echo -e "${GREEN}║${NC} SSL:             ${GREEN}Let's Encrypt${NC}"
else
echo -e "${GREEN}║${NC} Nginx:           ${YELLOW}Not installed${NC}"
fi
echo -e "${GREEN}║${NC} Firewall (UFW):  ${GREEN}Enabled${NC}"
if [ "$SETUP_SWAP" = "yes" ]; then
echo -e "${GREEN}║${NC} Swap:            ${GREEN}Enabled${NC} (${SWAP_SIZE_MB}MB)"
fi
if [ "$SETUP_BACKUP" = "yes" ]; then
echo -e "${GREEN}║${NC} Backups:         ${GREEN}Daily at $BACKUP_HOUR${NC} (retain ${BACKUP_RETENTION}d, filestore: $BACKUP_FILESTORE)"
echo -e "${GREEN}║${NC} Backup Dir:      $OE_HOME/backups"
else
echo -e "${GREEN}║${NC} Backups:         ${YELLOW}Not configured${NC}"
fi
echo -e "${GREEN}║${NC} Logrotate:       ${GREEN}Configured${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} ${RED}IMPORTANT: Save the admin password shown above!${NC}"
echo -e "${GREEN}║${NC} ${RED}It will not be displayed again.${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Drop the resume state on success — the answers file records the domain and
# certbot email, and there is nothing left to resume.
sudo rm -f "$CHECKPOINT_FILE" "$ANSWERS_FILE"

log_success "All done! Odoo $OE_VERSION is running as '$OE_USER'."
