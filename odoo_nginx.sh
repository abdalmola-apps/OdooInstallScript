#!/bin/bash

# ==============================================================================
# Odoo Nginx + SSL Setup Script
#
# Standalone script to install and configure Nginx as a reverse proxy for Odoo
# with Let's Encrypt SSL via Certbot.
#
# Usage:
#   sudo ./odoo_nginx.sh -u <username> -d <domain> -e <email> [-p <port>] [-l <longpolling_port>]
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
OE_DOMAIN=""
CERTBOT_EMAIL=""
OE_PORT=8069
OE_LONGPOLLING_PORT=""

# ==============================================================================
# Utility Functions
# ==============================================================================

log_info()    { echo -e "${BLUE}[INFO $(date '+%H:%M:%S')]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN $(date '+%H:%M:%S')]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR $(date '+%H:%M:%S')]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK   $(date '+%H:%M:%S')]${NC} $*"; }

# --- Validators ---

validate_username() {
    [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1024 && $1 <= 65535 ))
}

validate_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]
}

validate_email() {
    [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# ==============================================================================
# Usage / Help
# ==============================================================================

usage() {
    cat <<EOF
Odoo Nginx + SSL Setup Script v${SCRIPT_VERSION}

Usage: sudo $0 -u <username> -d <domain> -e <email> [OPTIONS]

Required:
  -u <username>           Odoo system user (for log naming)
  -d <domain>             Fully Qualified Domain Name (e.g., odoo.example.com)
  -e <email>              Email for Let's Encrypt SSL certificate

Options:
  -p <port>               Odoo HTTP port (default: 8069)
  -l <longpolling_port>   Longpolling port (default: port + 1)
  -h                      Show this help message

Examples:
  # Basic setup
  sudo $0 -u odoo18 -d erp.mycompany.com -e admin@mycompany.com

  # Custom ports
  sudo $0 -u odoo18 -d erp.mycompany.com -e admin@mycompany.com -p 8015 -l 8016
EOF
    exit 0
}

# ==============================================================================
# Parse Arguments
# ==============================================================================

while getopts ":u:d:e:p:l:h" opt; do
    case "$opt" in
        u) OE_USER="$OPTARG" ;;
        d) OE_DOMAIN="$OPTARG" ;;
        e) CERTBOT_EMAIL="$OPTARG" ;;
        p) OE_PORT="$OPTARG" ;;
        l) OE_LONGPOLLING_PORT="$OPTARG" ;;
        h) usage ;;
        :) log_error "Option -$OPTARG requires an argument."; exit 1 ;;
        *) log_error "Unknown option: -$OPTARG"; usage ;;
    esac
done

# Default longpolling port = port + 1
if [ -z "$OE_LONGPOLLING_PORT" ]; then
    OE_LONGPOLLING_PORT=$((OE_PORT + 1))
fi

# ==============================================================================
# Validation
# ==============================================================================

ERRORS=0

if [ -z "$OE_USER" ]; then
    log_error "Username is required (-u)."
    ERRORS=$((ERRORS + 1))
elif ! validate_username "$OE_USER"; then
    log_error "Invalid username: '$OE_USER'. Use letters, digits, underscores."
    ERRORS=$((ERRORS + 1))
fi

if [ -z "$OE_DOMAIN" ]; then
    log_error "Domain is required (-d)."
    ERRORS=$((ERRORS + 1))
elif ! validate_domain "$OE_DOMAIN"; then
    log_error "Invalid domain: '$OE_DOMAIN'. Enter a valid FQDN."
    ERRORS=$((ERRORS + 1))
fi

if [ -z "$CERTBOT_EMAIL" ]; then
    log_error "Email is required (-e)."
    ERRORS=$((ERRORS + 1))
elif ! validate_email "$CERTBOT_EMAIL"; then
    log_error "Invalid email: '$CERTBOT_EMAIL'."
    ERRORS=$((ERRORS + 1))
fi

if ! validate_port "$OE_PORT"; then
    log_error "Invalid port: '$OE_PORT'. Must be 1024-65535."
    ERRORS=$((ERRORS + 1))
fi

if ! validate_port "$OE_LONGPOLLING_PORT"; then
    log_error "Invalid longpolling port: '$OE_LONGPOLLING_PORT'. Must be 1024-65535."
    ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
    echo "Run '$0 -h' for help."
    exit 1
fi

# ==============================================================================
# Root Check
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root (use sudo)."
    exit 1
fi

# ==============================================================================
# Start Setup
# ==============================================================================

OE_HOME="/home/$OE_USER"

echo ""
log_info "=== Odoo Nginx Setup v${SCRIPT_VERSION} ==="
log_info "User: $OE_USER | Domain: $OE_DOMAIN | Port: $OE_PORT | LP: $OE_LONGPOLLING_PORT"
echo ""

# ==============================================================================
# Step 1: Install Nginx & Certbot
# ==============================================================================

log_info "Installing Nginx and Certbot (waits for the dpkg lock if held)..."
# DPkg::Lock::Timeout stops unattended-upgrades holding the lock from aborting
# the run; the frontend vars stop debconf/needrestart opening a dialog.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
readonly APT_OPTS=(-o DPkg::Lock::Timeout=600
                   -o Dpkg::Options::=--force-confold
                   -o Dpkg::Options::=--force-confdef)
apt-get "${APT_OPTS[@]}" update -qq
apt-get "${APT_OPTS[@]}" install -y nginx certbot python3-certbot-nginx
log_success "Nginx and Certbot installed."

# ==============================================================================
# Step 2: Write Nginx Site Config
# ==============================================================================

log_info "Creating Nginx site config for $OE_DOMAIN..."

# Upstream and map names are namespaced by user: they live in the shared http{}
# scope, so a second instance reusing "odoo_backend"/"$connection_upgrade" makes
# nginx refuse to start with a duplicate-name error and takes down the first site.
tee "/etc/nginx/sites-available/$OE_DOMAIN" > /dev/null <<NGINX_CONF
upstream ${OE_USER}_odoo {
    server 127.0.0.1:$OE_PORT;
}

upstream ${OE_USER}_gevent {
    server 127.0.0.1:$OE_LONGPOLLING_PORT;
}

# WebSocket upgrade map
map \$http_upgrade \$${OE_USER}_conn_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name $OE_DOMAIN;

    # Logging
    access_log /var/log/nginx/${OE_USER}-odoo-access.log;
    error_log  /var/log/nginx/${OE_USER}-odoo-error.log;

    # Max upload size
    client_max_body_size 200m;

    # Gzip compression
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;
    gzip_min_length 1000;

    # Proxy headers
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    # Security headers. HSTS is ignored by browsers over plain HTTP (RFC 6797),
    # so it is harmless before Certbot runs and active the moment it succeeds.
    # Certbot converts this same block to :443, carrying these headers with it.
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy no-referrer-when-downgrade always;

    # WebSocket / longpolling
    location /websocket {
        proxy_pass http://${OE_USER}_gevent;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$${OE_USER}_conn_upgrade;
    }

    location /longpolling {
        proxy_pass http://${OE_USER}_gevent;
    }

    # Cache every module's static assets, not just /web/static — Odoo serves
    # them from /<module>/static/. No add_header here on purpose: any add_header
    # in a location drops the server-level security headers above.
    location ~* ^/[a-zA-Z0-9_]+/static/ {
        proxy_pass http://${OE_USER}_odoo;
        expires 24h;
    }

    # Default — proxy to Odoo
    location / {
        proxy_pass http://${OE_USER}_odoo;
        proxy_redirect off;
    }
}
NGINX_CONF

log_success "Nginx site config written to /etc/nginx/sites-available/$OE_DOMAIN"

# ==============================================================================
# Step 3: Enable Site & Reload Nginx
# ==============================================================================

log_info "Enabling site and reloading Nginx..."

# Enable site
ln -sf "/etc/nginx/sites-available/$OE_DOMAIN" "/etc/nginx/sites-enabled/$OE_DOMAIN"

# Remove default site if it exists
if [ -f /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
fi

# Test before reloading, and unlink on failure — a broken file left in
# sites-enabled makes every later `systemctl reload nginx` fail, including
# reloads for unrelated sites on this server.
if ! nginx -t; then
    log_error "Nginx config test failed — disabling the new site and aborting."
    rm -f "/etc/nginx/sites-enabled/$OE_DOMAIN"
    exit 1
fi

systemctl reload nginx
log_success "Nginx reloaded with new config."

# ==============================================================================
# Step 4: Let's Encrypt SSL
# ==============================================================================

# Pre-flight: a domain that does not point here is the usual cause of a failed
# issuance, and Let's Encrypt rate-limits failures to 5/hostname/hour — cheap to
# check with getent (glibc, no dnsutils needed) before spending an attempt.
RESOLVED_IPS="$(getent ahosts "$OE_DOMAIN" | awk '{print $1}' | sort -u || true)"
if [ -z "$RESOLVED_IPS" ]; then
    log_warn "$OE_DOMAIN does not resolve. Certbot will almost certainly fail."
    log_warn "Add an A record pointing to this server, then re-run this script."
elif ! comm -12 <(echo "$RESOLVED_IPS") <(hostname -I | tr ' ' '\n' | sort -u) | grep -q .; then
    log_warn "$OE_DOMAIN resolves to: $(echo "$RESOLVED_IPS" | tr '\n' ' ')"
    log_warn "None of those match a local address. Fine behind NAT/Cloudflare/a load"
    log_warn "balancer — otherwise the certificate request will fail."
fi

log_info "Requesting SSL certificate for $OE_DOMAIN..."
# --redirect: force HTTP->HTTPS instead of leaving it to the certbot default,
#             which has varied across releases.
# --keep-until-expiring: makes re-runs idempotent rather than reissuing and
#             burning the 5-duplicate-certs-per-week rate limit.
if certbot --nginx -d "$OE_DOMAIN" \
    --non-interactive --agree-tos --redirect --keep-until-expiring \
    -m "$CERTBOT_EMAIL"; then
    log_success "SSL certificate obtained and installed."

    # HTTP/2 — Odoo loads many small assets, so multiplexing is a real first-paint
    # win, and Certbot never enables it. nginx 1.25.1+ prefers a separate
    # `http2 on;` but still accepts this form; every nginx Ubuntu 20.04-24.04
    # ships (1.18-1.24) only accepts this one.
    SITE_CONF="/etc/nginx/sites-available/$OE_DOMAIN"
    sed -i '/listen .*443 ssl/{/http2/!s/ ssl/ ssl http2/}' "$SITE_CONF"

    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        log_success "HTTP/2 enabled."
    else
        log_warn "HTTP/2 edit did not validate — reverting it."
        sed -i 's/ ssl http2/ ssl/' "$SITE_CONF"
        nginx -t && systemctl reload nginx
    fi

    # Renewal is a systemd timer from the certbot package; confirm it is armed,
    # otherwise the certificate silently expires in 90 days.
    if systemctl is-enabled certbot.timer >/dev/null 2>&1; then
        log_success "Auto-renewal active (certbot.timer)."
    else
        log_warn "certbot.timer is not enabled — enabling it."
        systemctl enable --now certbot.timer || \
            log_warn "Could not enable certbot.timer. Renew manually: sudo certbot renew"
    fi
else
    log_warn "Certbot failed — the site is still served over plain HTTP on port 80."
    log_warn "Common causes: DNS not pointing here, or port 80 blocked upstream."
    log_warn "Retry with: sudo certbot --nginx -d $OE_DOMAIN -m $CERTBOT_EMAIL --redirect"
fi

# ==============================================================================
# Step 5: Update Odoo Config (if found)
# ==============================================================================

# Search for Odoo config file
OE_CONFIG_FILE=""
for candidate in "$OE_HOME/${OE_USER}-odoo.conf" "$OE_HOME/odoo.conf"; do
    if [ -f "$candidate" ]; then
        OE_CONFIG_FILE="$candidate"
        break
    fi
done

if [ -n "$OE_CONFIG_FILE" ]; then
    log_info "Found Odoo config at $OE_CONFIG_FILE"

    if grep -q "^proxy_mode" "$OE_CONFIG_FILE"; then
        sed -i 's/^proxy_mode.*/proxy_mode = True/' "$OE_CONFIG_FILE"
    elif grep -q "^; Security" "$OE_CONFIG_FILE"; then
        sed -i '/^; Security/a proxy_mode = True' "$OE_CONFIG_FILE"
    else
        echo "proxy_mode = True" >> "$OE_CONFIG_FILE"
    fi

    log_success "Set proxy_mode = True in $OE_CONFIG_FILE"

    # Restart only if it is already running. Called from odoo_install.sh this is
    # step 15, before the service starts at step 18 — it picks the setting up on
    # its first start, so there is nothing to do here.
    if systemctl is-active --quiet "${OE_USER}-odoo.service"; then
        log_info "Restarting ${OE_USER}-odoo.service to apply proxy_mode..."
        systemctl restart "${OE_USER}-odoo.service"
        log_success "Odoo restarted."
    fi
else
    log_warn "No Odoo config file found. Set proxy_mode = True manually."
fi

# ==============================================================================
# Summary
# ==============================================================================

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            Nginx Setup Complete!                        ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC} Domain:          ${BLUE}$OE_DOMAIN${NC}"
echo -e "${GREEN}║${NC} Odoo Port:       $OE_PORT"
echo -e "${GREEN}║${NC} Longpolling:     $OE_LONGPOLLING_PORT"
echo -e "${GREEN}║${NC} SSL:             Let's Encrypt"
echo -e "${GREEN}║${NC} Config:          /etc/nginx/sites-available/$OE_DOMAIN"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC} Test Commands:"
echo -e "${GREEN}║${NC}   ${YELLOW}sudo nginx -t${NC}"
echo -e "${GREEN}║${NC}   ${YELLOW}sudo systemctl status nginx${NC}"
echo -e "${GREEN}║${NC}   ${YELLOW}curl -I https://$OE_DOMAIN${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
