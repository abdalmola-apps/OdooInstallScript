#!/bin/bash

# ==============================================================================
# Odoo SSL Certificate Script
#
# Reports on the Let's Encrypt certificates on this server and renews the ones
# that are due.
#
# Certbot already renews on its own through certbot.timer, so the useful part of
# this is the report: days left, which names each certificate actually covers,
# and whether Nginx is serving a name the certificate does not cover — the
# failure that shows up as "Not secure" in a browser while the timer reports
# nothing wrong. Renewal here is `certbot renew`, no reimplementation.
#
# Usage:
#   sudo ./odoo_ssl.sh [-u <username>] [-d <domain>] [-f] [-t]
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

readonly LE_LIVE="/etc/letsencrypt/live"
readonly SITES_AVAILABLE="/etc/nginx/sites-available"

# Certbot renews inside this window; outside it `certbot renew` is a no-op.
readonly RENEW_WINDOW_DAYS=30

OE_USER=""
OE_DOMAIN=""
FORCE=false
DRY_RUN=false

log_info()    { echo -e "${BLUE}[INFO $(date '+%H:%M:%S')]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN $(date '+%H:%M:%S')]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR $(date '+%H:%M:%S')]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK   $(date '+%H:%M:%S')]${NC} $*"; }

validate_username() {
    [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

usage() {
    cat <<EOF
Odoo SSL Certificate Script v${SCRIPT_VERSION}

Usage: sudo $0 [OPTIONS]

Options:
  -u <username>    Only this instance's certificate. The domain is read from
                   the Nginx site that owns the '<username>_odoo' upstream.
  -d <domain>      Only the certificate covering this domain.
  -f               Force renewal even when the certificate is not due.
                   Let's Encrypt allows 5 duplicate certificates per week —
                   use this to replace a broken certificate, not routinely.
  -t               Test only: 'certbot renew --dry-run'. Changes nothing and
                   does not count against any rate limit.
  -h               Show this help message

With no -u and no -d this covers every certificate on the server.

Renewal is already automatic through certbot.timer; this reports on it and
gives you a way to renew on demand. A certificate is renewed only inside its
last ${RENEW_WINDOW_DAYS} days unless -f is given.

Examples:
  # Report on every certificate, renew whatever is due
  sudo $0

  # Verify renewal works, without touching anything
  sudo $0 -t

  # Replace one instance's certificate now
  sudo $0 -u odoo18 -f
EOF
    exit 0
}

while getopts ":u:d:fth" opt; do
    case "$opt" in
        u) OE_USER="$OPTARG" ;;
        d) OE_DOMAIN="$OPTARG" ;;
        f) FORCE=true ;;
        t) DRY_RUN=true ;;
        h) usage ;;
        :) log_error "Option -$OPTARG requires an argument."; exit 1 ;;
        *) log_error "Unknown option: -$OPTARG"; usage ;;
    esac
done

# ==============================================================================
# Validation
# ==============================================================================

# Root: the certificates and their private keys are readable only by root.
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)."
    exit 1
fi

if ! command -v certbot &> /dev/null; then
    log_error "certbot is not installed — there are no Let's Encrypt certificates."
    log_error "Set up a site first: sudo abo nginx -u <user> -d <domain> -e <email>"
    exit 1
fi

if [ -n "$OE_USER" ] && ! validate_username "$OE_USER"; then
    log_error "Invalid username: '$OE_USER'."
    exit 1
fi

if [ "$FORCE" = true ] && [ "$DRY_RUN" = true ]; then
    log_error "-f and -t are mutually exclusive."
    exit 1
fi

# ==============================================================================
# Helpers
# ==============================================================================

# Every DNS name a certificate covers.
cert_names() {
    openssl x509 -noout -ext subjectAltName -in "$1" 2>/dev/null \
        | tr ',' '\n' | sed -n 's/.*DNS://p' | tr -d ' ' | grep -v '^$' | sort -u
}

# Days until expiry — negative once expired.
cert_days_left() {
    local end epoch
    end="$(openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2)"
    [ -n "$end" ] || return 1
    epoch="$(date -d "$end" +%s 2>/dev/null)" || return 1
    echo $(( (epoch - $(date +%s)) / 86400 ))
}

# Every name the Nginx site serves. Certbot splits the site into a redirect
# block and a TLS block with the same server_name, so the first one is enough.
site_names() {
    awk '/^[[:space:]]*server_name[[:space:]]/ {
             sub(/;.*/, ""); sub(/^[[:space:]]*server_name[[:space:]]+/, "");
             print; exit
         }' "$1" | tr ' ' '\n' | grep -v '^$' | sort -u
}

# The site config serving a domain: named after it by odoo_nginx.sh, otherwise
# found by its server_name.
site_conf_for() {
    local domain="$1"
    [ -d "$SITES_AVAILABLE" ] || return 1
    if [ -f "$SITES_AVAILABLE/$domain" ]; then
        printf '%s\n' "$SITES_AVAILABLE/$domain"
        return 0
    fi
    grep -rlE "^[[:space:]]*server_name[[:space:]].*[[:space:]]?${domain}[[:space:];]" \
        "$SITES_AVAILABLE/" 2>/dev/null | head -1 | grep . || return 1
}

# ==============================================================================
# Resolve which certificates to act on
# ==============================================================================

# -u names an instance, not a domain: find the site holding its upstream block
# and read the domain back out of it. Same lookup odoo_remove.sh uses, because
# sites are named after the domain and nothing records the reverse mapping.
if [ -n "$OE_USER" ]; then
    if [ -n "$OE_DOMAIN" ]; then
        log_warn "-d given as well as -u; using -d $OE_DOMAIN."
    else
        if [ ! -d "$SITES_AVAILABLE" ]; then
            log_error "Nginx is not installed — cannot resolve a domain for '$OE_USER'."
            exit 1
        fi
        SITE=$(grep -rlE "^[[:space:]]*upstream[[:space:]]+${OE_USER}_odoo[[:space:]]*\{" \
            "$SITES_AVAILABLE/" 2>/dev/null | head -1) || true
        if [ -z "$SITE" ]; then
            log_error "No Nginx site owns the '${OE_USER}_odoo' upstream."
            log_error "That instance has no reverse proxy: sudo abo nginx -u $OE_USER ..."
            exit 1
        fi
        OE_DOMAIN=$(site_names "$SITE" | head -1)
        if [ -z "$OE_DOMAIN" ]; then
            log_error "$SITE has no server_name to take a domain from."
            exit 1
        fi
        log_info "Instance '$OE_USER' serves $OE_DOMAIN (from $(basename "$SITE"))."
    fi
fi

# Lineages are usually named after their first domain, but certbot appends -0001
# on a collision — so match on what each certificate actually covers.
LINEAGES=()
if [ -d "$LE_LIVE" ]; then
    for chain in "$LE_LIVE"/*/fullchain.pem; do
        [ -f "$chain" ] || continue
        name="$(basename "$(dirname "$chain")")"
        if [ -n "$OE_DOMAIN" ] && ! cert_names "$chain" | grep -qxF "$OE_DOMAIN"; then
            continue
        fi
        LINEAGES+=("$name")
    done
fi

if [ ${#LINEAGES[@]} -eq 0 ]; then
    if [ -n "$OE_DOMAIN" ]; then
        log_error "No certificate on this server covers $OE_DOMAIN."
        log_error "Issue one: sudo abo nginx -u <user> -d $OE_DOMAIN -e <email>"
    else
        log_error "No Let's Encrypt certificates found in $LE_LIVE."
        log_error "Issue one: sudo abo nginx -u <user> -d <domain> -e <email>"
    fi
    exit 1
fi

# ==============================================================================
# Report
# ==============================================================================

echo ""
log_info "=== Odoo SSL v${SCRIPT_VERSION} ==="
echo ""

DUE=0
EXPIRED=0
UNCOVERED=""

for name in "${LINEAGES[@]}"; do
    chain="$LE_LIVE/$name/fullchain.pem"
    names="$(cert_names "$chain" | tr '\n' ' ')"

    if ! days="$(cert_days_left "$chain")"; then
        log_warn "$name — cannot read expiry from $chain"
        continue
    fi

    if [ "$days" -lt 0 ]; then
        EXPIRED=$((EXPIRED + 1))
        state="${RED}EXPIRED $(( -days )) day(s) ago${NC}"
    elif [ "$days" -le "$RENEW_WINDOW_DAYS" ]; then
        DUE=$((DUE + 1))
        state="${YELLOW}$days day(s) left — due for renewal${NC}"
    else
        state="${GREEN}$days day(s) left${NC}"
    fi

    echo -e "  ${BLUE}$name${NC}"
    echo -e "    Expires:  $state"
    echo -e "    Covers:   ${names% }"

    # A name Nginx serves but the certificate omits is the "Not secure" bug:
    # the site is the default server, so it answers for that name regardless,
    # and hands over a certificate that does not match it.
    if conf="$(site_conf_for "$name")"; then
        missing="$(comm -23 <(site_names "$conf") <(cert_names "$chain") | tr '\n' ' ')"
        if [ -n "${missing// /}" ]; then
            echo -e "    ${YELLOW}Served but NOT on the certificate: ${missing% }${NC}"
            UNCOVERED="$UNCOVERED $name"
        fi
    fi
    echo ""
done

if [ -n "$UNCOVERED" ]; then
    log_warn "Some served names are not on their certificate — browsers will"
    log_warn "report those as not secure. Re-run the Nginx step to add them:"
    log_warn "  sudo abo nginx -u <user> -d <domain> -e <email>"
    echo ""
fi

# ==============================================================================
# Renew
# ==============================================================================

# --cert-name takes one lineage and the last one wins, so a scoped run has to
# call certbot once per certificate rather than listing them.
certbot_renew() {
    local rc=0 n
    if [ -z "$OE_DOMAIN" ]; then
        certbot renew "$@"
        return
    fi
    for n in "${LINEAGES[@]}"; do
        certbot renew --cert-name "$n" "$@" || rc=1
    done
    return "$rc"
}

RENEW_STATUS=""

if [ "$DRY_RUN" = true ]; then
    log_info "Test run — nothing will be changed."
    if certbot_renew --dry-run; then
        RENEW_STATUS="dry run passed"
        log_success "Renewal works. Nothing was changed."
    else
        RENEW_STATUS="dry run FAILED"
        log_error "The dry run failed — a real renewal would fail the same way."
        log_error "Fix it before the certificate reaches its last $RENEW_WINDOW_DAYS days."
    fi
elif [ "$FORCE" = true ]; then
    log_warn "Forcing renewal. Let's Encrypt allows 5 duplicate certificates per"
    log_warn "week per domain set — repeated runs will hit that limit."
    if certbot_renew --force-renewal; then
        RENEW_STATUS="renewed (forced)"
        log_success "Certificate(s) renewed."
    else
        RENEW_STATUS="renewal FAILED"
        log_error "Forced renewal failed — see the certbot output above."
    fi
elif [ "$DUE" -eq 0 ] && [ "$EXPIRED" -eq 0 ]; then
    RENEW_STATUS="nothing due"
    log_success "Nothing is due for renewal. Use -f to renew anyway."
else
    if certbot_renew; then
        RENEW_STATUS="renewed"
        log_success "Renewal run complete."
    else
        RENEW_STATUS="renewal FAILED"
        log_error "Renewal failed — see the certbot output above."
    fi
fi

# Certbot reloads Nginx itself through the installer recorded in each renewal
# config, but that record is only there when the certificate was issued with
# --nginx. Reloading again is free and covers the ones that were not.
if [ "$DRY_RUN" = false ] && [[ "$RENEW_STATUS" == renewed* ]]; then
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        log_success "Nginx reloaded."
    else
        log_warn "nginx -t failed — not reloading. Run 'sudo nginx -t' to see why."
    fi
fi

# ==============================================================================
# Auto-renewal
# ==============================================================================

# The certificate expiring is not the failure mode that bites people — the timer
# never having been armed is, and that is silent for 90 days.
TIMER_STATUS=""
if systemctl is-enabled certbot.timer >/dev/null 2>&1; then
    NEXT="$(systemctl show certbot.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)"
    TIMER_STATUS="active${NEXT:+, next ${NEXT}}"
    log_success "Auto-renewal is armed (certbot.timer)."
else
    log_warn "certbot.timer is not enabled — certificates would expire silently."
    if systemctl enable --now certbot.timer 2>/dev/null; then
        TIMER_STATUS="enabled just now"
        log_success "Enabled certbot.timer."
    else
        TIMER_STATUS="NOT active"
        log_error "Could not enable certbot.timer. Renew manually: sudo certbot renew"
    fi
fi

# ==============================================================================
# Summary
# ==============================================================================

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}                    SSL CERTIFICATE SUMMARY                   ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo -e "${GREEN}║${NC} Certificates:   ${#LINEAGES[@]}"
echo -e "${GREEN}║${NC} Due / expired:  $DUE / $EXPIRED"
echo -e "${GREEN}║${NC} Action:         $RENEW_STATUS"
echo -e "${GREEN}║${NC} Auto-renewal:   $TIMER_STATUS"
if [ -n "$UNCOVERED" ]; then
    echo -e "${GREEN}║${NC} ${YELLOW}Uncovered names:${NC}${UNCOVERED}"
fi
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ "$RENEW_STATUS" == *FAILED* ]]; then
    exit 1
fi
