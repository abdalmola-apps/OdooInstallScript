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

log_info "Installing Nginx and Certbot..."
apt-get update -qq
apt-get install -y nginx certbot python3-certbot-nginx
log_success "Nginx and Certbot installed."

# ==============================================================================
# Step 2: Write Nginx Site Config
# ==============================================================================

log_info "Creating Nginx site config for $OE_DOMAIN..."

tee "/etc/nginx/sites-available/$OE_DOMAIN" > /dev/null <<NGINX_CONF
# Odoo upstream
upstream odoo_backend {
    server 127.0.0.1:$OE_PORT;
}

upstream odoo_longpolling {
    server 127.0.0.1:$OE_LONGPOLLING_PORT;
}

# WebSocket upgrade map
map \$http_upgrade \$connection_upgrade {
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

    # WebSocket / longpolling
    location /websocket {
        proxy_pass http://odoo_longpolling;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location /longpolling {
        proxy_pass http://odoo_longpolling;
    }

    # Static file caching
    location ~* /web/static/ {
        proxy_pass http://odoo_backend;
        proxy_cache_valid 200 60m;
        expires 24h;
        add_header Cache-Control "public, no-transform";
    }

    # Default — proxy to Odoo
    location / {
        proxy_pass http://odoo_backend;
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

# Test and reload
nginx -t
systemctl reload nginx
log_success "Nginx reloaded with new config."

# ==============================================================================
# Step 4: Let's Encrypt SSL
# ==============================================================================

log_info "Requesting SSL certificate for $OE_DOMAIN..."
if certbot --nginx -d "$OE_DOMAIN" \
    --non-interactive --agree-tos -m "$CERTBOT_EMAIL"; then
    log_success "SSL certificate obtained and installed."
else
    log_warn "Certbot failed. You can retry later with:"
    log_warn "  sudo certbot --nginx -d $OE_DOMAIN -m $CERTBOT_EMAIL"
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
    log_warn "Restart Odoo for proxy_mode to take effect."
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
