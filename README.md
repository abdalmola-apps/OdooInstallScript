# Odoo Production Installation Script

Automated Bash script for deploying production-grade Odoo instances on Ubuntu servers. Handles everything from system setup to Nginx reverse proxy with SSL, firewall, swap, log rotation, and auto-tuned performance settings.

## Features

- **Production-Ready**: Nginx reverse proxy, Let's Encrypt SSL, UFW firewall, logrotate, swap
- **Automated Backups**: Daily database backups sorted by activity, with filestore support and retention cleanup
- **Auto-Tuned Performance**: Workers, memory limits, and DB connections computed from CPU cores and RAM
- **Security Hardened**: Random admin password, no PostgreSQL superuser, config file chmod 640, input validation
- **Multi-Instance Support**: Run multiple Odoo instances on the same server with different users and ports
- **Multiple Addon Repos**: Clone several custom addon repositories in a single run
- **Checkpoint System**: Resume installation from where it left off if interrupted
- **Auto-Detect wkhtmltopdf**: Selects the correct `.deb` for your Ubuntu codename and CPU architecture
- **Standalone Scripts**: Nginx and backup scripts can be used independently of the installer
- **Input Validation**: All prompts validated with re-prompt loops (username, port, version, Git URLs, domain, email)

## Prerequisites

- Ubuntu 20.04+ (tested on Ubuntu 22.04 Jammy and 24.04 Noble)
- Root or sudo access
- Internet connection
- A domain name pointing to your server (if using Nginx + SSL)

## Quick Start

### Download and Run

```bash
wget https://raw.githubusercontent.com/abdalmola-apps/OdooInstallScript/main/odoo_install.sh
chmod +x odoo_install.sh
sudo ./odoo_install.sh
```

### From Cloned Repository

```bash
git clone https://github.com/abdalmola-apps/OdooInstallScript.git
cd OdooInstallScript
chmod +x odoo_install.sh
sudo ./odoo_install.sh
```

## Interactive Prompts

The script prompts for the following (with validation and defaults):

| Prompt | Default | Validation |
|--------|---------|------------|
| System username | *(required)* | Alphanumeric + underscore |
| Odoo version | `18.0` | Format: `XX.0` |
| HTTP port | `8069` | Range: 1024-65535 |
| Install Nginx? | `no` | yes/no |
| Domain name | *(required if Nginx)* | Valid FQDN |
| Certbot email | *(required if Nginx)* | Valid email |
| Custom addon Git URLs | *(optional)* | Comma-separated, validated |
| Set up swap? | Auto (`yes` if RAM < 4GB) | yes/no |
| Set up daily backups? | `yes` | yes/no |
| Include filestore? | `yes` *(if backups)* | yes/no |
| Retention days | `30` *(if backups)* | Positive integer |
| Backup time | `02:00` *(if backups)* | HH:MM (24h) |

A confirmation summary is displayed before any changes are made.

### Example Session

```
Enter the Odoo system username: odoo18
Enter the Odoo version [18.0]: 18.0
Enter the Odoo HTTP port [8069]: 8069
Install Nginx as reverse proxy? (yes/no) [no]: yes
Enter the domain name (e.g., odoo.example.com): erp.mycompany.com
Enter email for Let's Encrypt SSL certificate: admin@mycompany.com
Enter custom addon Git URLs (comma-separated, or leave empty): https://github.com/mycompany/custom-addons
Set up swap file? (yes/no) [yes]: yes
Set up automated daily backups? (yes/no) [yes]: yes
Include filestore in backups? (yes/no) [yes]: yes
Backup retention in days [30]: 30
Backup time (HH:MM, 24h format) [02:00]: 02:00

╔══════════════════════════════════════════════════════════╗
║                  Installation Summary                   ║
╠══════════════════════════════════════════════════════════╣
║ Username:        odoo18
║ Odoo Version:    18.0
║ HTTP Port:       8069
║ Longpolling:     8070
║ Workers:         5 (CPU: 2, RAM: 4096MB)
║ Nginx + SSL:     yes
║ Domain:          erp.mycompany.com
║ Addon Repos:     1
║ Swap:            yes
║ Daily Backups:   yes
║   Filestore:     yes
║   Retention:     30 days
║   Schedule:      Daily at 02:00
╚══════════════════════════════════════════════════════════╝

Proceed with installation? (yes/no): yes
```

## Installation Steps

The script performs 19 automated steps:

| Step | Description |
|------|-------------|
| 1 | Check & install PostgreSQL |
| 2 | Set timezone to Asia/Riyadh |
| 3 | Create system user & PostgreSQL user (no superuser) |
| 4 | Clone Odoo source code |
| 5 | Install system dependencies & auto-detect wkhtmltopdf |
| 6 | Create Python venv & install dependencies |
| 7 | Install Node.js, LESS & rtlcss |
| 8 | Create data & custom-addons directories |
| 9 | Generate Ed25519 SSH key |
| 10 | Clone custom addon repositories |
| 11 | Generate Odoo config (auto-tuned workers & memory) |
| 12 | Create systemd service file |
| 13 | Set ownership & permissions |
| 14 | Configure logrotate |
| 15 | Configure Nginx & Let's Encrypt SSL *(conditional, uses `odoo_nginx.sh`)* |
| 16 | Configure UFW firewall |
| 17 | Set up swap file *(conditional)* |
| 18 | Enable & start Odoo service |
| 19 | Set up automated daily backups *(conditional, uses `odoo_backup.sh`)* |

## What Gets Installed

### System Packages
- PostgreSQL and postgresql-contrib
- Python 3 development tools (python3-dev, python3-venv, python3-wheel, python3-setuptools)
- Build tools (build-essential, git, wget, curl)
- Required libraries (libxslt-dev, libzip-dev, libldap2-dev, libsasl2-dev, libpq-dev, libpng-dev, libjpeg-dev)
- Node.js, npm, LESS, rtlcss
- wkhtmltopdf 0.12.6.1-2 (patched Qt version, auto-detected for your OS)
- UFW firewall
- Nginx + Certbot *(optional)*

### Python Packages (in virtual environment)
- All packages from Odoo's `requirements.txt`
- num2words, ofxparse, dbfread, ebaysdk, firebase_admin, pyOpenSSL
- Additional packages from this repository's `requirements.txt` (if present)

## Security

The script applies production security practices by default:

| Area | What's Done |
|------|-------------|
| Admin password | Random 24-character password generated via `openssl rand` |
| PostgreSQL user | Created with `--no-superuser --no-createrole` (only `--createdb`) |
| Config file | `chmod 640` — readable only by Odoo user and root |
| Service file | `chmod 644` — standard systemd permissions |
| Database listing | `list_db = False` — hides database manager |
| Firewall | UFW enabled: SSH, 80, 443 allowed; direct Odoo port only if no Nginx |
| Proxy mode | `proxy_mode = True` when Nginx is enabled |
| Input validation | All user inputs validated before use to prevent injection |

## Auto-Tuned Configuration

The Odoo config file is computed based on your server's hardware:

```
workers         = min(CPU_CORES * 2 + 1, RAM_MB / 256)    # at least 2
max_cron_threads = 1
limit_memory_soft = (RAM * 0.8) / (workers + cron + 1)
limit_memory_hard = soft * 1.2
limit_time_cpu   = 600
limit_time_real  = 1200
db_maxconn       = workers * 2 + 4
```

Example for a 2-core / 4GB server: 5 workers, ~550MB soft limit per worker, 14 max DB connections.

## Nginx Reverse Proxy

When Nginx is enabled, the script creates a full production config with:

- Upstream blocks for Odoo HTTP and longpolling
- WebSocket support (`/websocket` location with upgrade headers)
- Longpolling proxy (`/longpolling`)
- Static file caching (`/web/static/` with 24h expiry)
- Gzip compression on text types
- Proper proxy headers (`X-Forwarded-Host`, `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Real-IP`)
- `client_max_body_size 200m`
- Let's Encrypt SSL via Certbot (automated, with graceful fallback)

## Automated Backups

When backups are enabled during installation, the script installs `odoo_backup.sh` and a cron job that runs daily at 2:00 AM.

### What It Does

1. Discovers all PostgreSQL databases owned by the Odoo user
2. Queries each database for the latest `write_date` from `res_users`
3. Sorts databases by activity (most recently used first)
4. Creates compressed `pg_dump` backups (custom format, compression level 5)
5. Optionally archives the filestore directory for each database
6. Cleans up backups older than the retention period (default: 30 days)

### Backup Files

- **Database dumps**: `<dbname>_<timestamp>.dump` (restorable via `pg_restore`)
- **Filestore archives**: `<dbname>_filestore_<timestamp>.tar.gz`
- **Log**: `/home/<username>/data/backup.log`

### Running Manually

```bash
# Full backup with filestore
sudo ./odoo_backup.sh -u <username> -f

# Custom retention (14 days) and backup directory
sudo ./odoo_backup.sh -u <username> -f -r 14 -d /mnt/backups

# Quiet mode (for scripting)
sudo ./odoo_backup.sh -u <username> -f -q
```

### CLI Flags

| Flag | Description | Default |
|------|-------------|---------|
| `-u <username>` | Odoo system user (required) | — |
| `-d <dir>` | Backup directory | `/home/<user>/backups` |
| `-r <days>` | Delete backups older than N days | `30` |
| `-f` | Include filestore in backup | off |
| `-q` | Quiet mode (errors only) | off |
| `-h` | Show help | — |

### Restoring a Backup

```bash
# Restore database
sudo -u <username> pg_restore -d <new_dbname> --create /home/<username>/backups/<dbname>_<timestamp>.dump

# Restore filestore
sudo -u <username> tar -xzf /home/<username>/backups/<dbname>_filestore_<timestamp>.tar.gz -C /home/<username>/data/filestore/
```

## Standalone Nginx Setup

The Nginx configuration is available as a standalone script (`odoo_nginx.sh`) that can be run independently of the installer. This is useful for:

- Adding Nginx to an existing Odoo installation
- Reconfiguring Nginx with a different domain
- Setting up Nginx on a separate proxy server

### Usage

```bash
# Basic setup
sudo ./odoo_nginx.sh -u odoo18 -d erp.mycompany.com -e admin@mycompany.com

# Custom ports
sudo ./odoo_nginx.sh -u odoo18 -d erp.mycompany.com -e admin@mycompany.com -p 8015 -l 8016
```

### CLI Flags

| Flag | Description | Default |
|------|-------------|---------|
| `-u <username>` | Odoo system user (required) | — |
| `-d <domain>` | FQDN (required) | — |
| `-e <email>` | Let's Encrypt email (required) | — |
| `-p <port>` | Odoo HTTP port | `8069` |
| `-l <port>` | Longpolling port | port + 1 |
| `-h` | Show help | — |

### What It Does

1. Installs Nginx, Certbot, and python3-certbot-nginx
2. Writes the Nginx site config (upstream blocks, WebSocket support, static caching, gzip)
3. Enables the site, removes the default site, tests and reloads Nginx
4. Requests a Let's Encrypt SSL certificate via Certbot
5. Sets `proxy_mode = True` in the Odoo config (if found)

## wkhtmltopdf Auto-Detection

The script automatically selects the correct wkhtmltopdf package based on:

- **Ubuntu codename**: focal (20.04), jammy (22.04), noble (24.04)
- **Architecture**: amd64, arm64

Falls back to `jammy` if the codename is not recognized.

### Why the Patched Version?

The standard `apt` version uses an unpatched Qt library that doesn't support `--header-spacing`, `--header-html`, and `--footer-html` — required for proper PDF rendering in Odoo.

## Checkpoint System

The script saves progress after each step to `/tmp/odoo_setup_checkpoint_<username>`. If interrupted:

- Re-run the script with the same username
- Completed steps are automatically skipped
- Installation resumes from the last incomplete step
- On failure, the error handler shows which step failed and how to resume

The checkpoint file is removed on successful completion.

## Directory Structure

```
/home/<username>/
├── odoo/                    # Odoo source code
│   ├── addons/             # Standard Odoo addons
│   ├── odoo-bin            # Odoo executable
│   ├── venv/               # Python virtual environment
│   └── requirements.txt    # Python dependencies
├── data/                    # Odoo data directory
│   ├── odoo-server.log     # Log file (logrotate configured)
│   └── backup.log          # Backup script log (if backups enabled)
├── backups/                 # Database backups (if backups enabled)
│   ├── mydb_20260216_020000.dump
│   └── mydb_filestore_20260216_020000.tar.gz
├── custom-addons/           # Custom addon repositories
│   ├── <repo-1>/           # First cloned addon repo
│   └── <repo-2>/           # Second cloned addon repo
├── .ssh/                    # SSH keys for git operations
│   └── id_ed25519          # Ed25519 SSH key
├── odoo_backup.sh           # Backup script (if backups enabled)
├── odoo_nginx.sh            # Nginx setup script (if Nginx enabled)
└── <username>-odoo.conf    # Odoo configuration (chmod 640)
```

## Service Management

```bash
# Check status
sudo systemctl status <username>-odoo.service

# Start / Stop / Restart
sudo systemctl start <username>-odoo.service
sudo systemctl stop <username>-odoo.service
sudo systemctl restart <username>-odoo.service

# View live logs
sudo journalctl -u <username>-odoo.service -f
```

The systemd service includes:
- `Restart=on-failure` with `RestartSec=5`
- `LimitNOFILE=65536`
- `NODE_OPTIONS` for optimized Node.js memory usage
- PostgreSQL dependency (waits for database before starting)

## Logrotate

Logs are rotated automatically:
- **Frequency**: Weekly
- **Retention**: 12 rotations (3 months)
- **Compression**: Enabled (with delay)
- **Method**: `copytruncate` (no service restart needed)

Config file: `/etc/logrotate.d/<username>-odoo`

## Swap File

When enabled, the script creates a swap file:
- **Size**: Equal to RAM, capped at 4GB
- **Permissions**: `chmod 600`
- **Persistence**: Added to `/etc/fstab`
- **Auto-suggest**: Recommended when RAM < 4GB

## Multiple Instances

Run the script again with a different username and port. Each instance gets its own:
- System user and PostgreSQL user
- Odoo installation and venv
- Configuration and service files
- Log rotation config
- Nginx site config (if enabled)

## Additional Requirements

This repository includes a `requirements.txt` with commonly used Python packages:

| Category | Packages |
|----------|----------|
| CLI Tools | click-odoo, click-odoo-contrib |
| PDF/Reporting | PyPDF2, reportlab |
| Excel | xlrd, xlwt, openpyxl, xlsxwriter |
| Data Processing | pandas, numpy |
| API Integration | requests, zeep |
| Enhanced Features | num2words, ofxparse, dbfread, ebaysdk, firebase-admin, pyOpenSSL |

The script automatically detects and installs this file if present in the same directory.

### Manual Installation (Existing Setups)

```bash
sudo -u <username> /home/<username>/odoo/venv/bin/pip install -r requirements.txt
sudo systemctl restart <username>-odoo.service
```

## Troubleshooting

### Service won't start
```bash
# Check service logs
sudo journalctl -u <username>-odoo.service -n 50

# Check Odoo log file
tail -f /home/<username>/data/odoo-server.log

# Verify Python dependencies
sudo -u <username> /home/<username>/odoo/venv/bin/pip list
```

### Port already in use
```bash
sudo ss -tlnp | grep :<port>
```
Choose a different port and re-run the script.

### PostgreSQL connection issues
```bash
# Verify PostgreSQL user exists
sudo -u postgres psql -c "\du"

# Test connection
sudo -u <username> psql -l
```

### Nginx issues
```bash
# Test config syntax
sudo nginx -t

# Check Nginx error log
tail -f /var/log/nginx/<username>-odoo-error.log

# Retry SSL certificate
sudo certbot --nginx -d <domain> -m <email>
```

### Permission errors
```bash
sudo chown -R <username>:<username> /home/<username>/
```

## Uninstalling

```bash
# Stop and remove service
sudo systemctl stop <username>-odoo.service
sudo systemctl disable <username>-odoo.service
sudo rm /etc/systemd/system/<username>-odoo.service
sudo systemctl daemon-reload

# Remove backup cron job (if installed)
sudo crontab -l | grep -v "odoo_backup.sh" | sudo crontab -

# Remove Nginx site (if installed)
sudo rm -f /etc/nginx/sites-enabled/<domain>
sudo rm -f /etc/nginx/sites-available/<domain>
sudo systemctl reload nginx

# Remove logrotate config
sudo rm -f /etc/logrotate.d/<username>-odoo

# Remove PostgreSQL user and databases
sudo -u postgres dropuser <username>

# Remove system user and home directory (includes backups)
sudo userdel -r <username>
```

## License

`odoo_install.sh` is provided under LGPL-3.

## Author

**abdalmola**

Production-grade Odoo deployment automation for system administrators and DevOps engineers.
