# Odoo Production Installation Script

Automated Bash script for deploying production-grade Odoo instances on Ubuntu servers. Handles everything from system setup to Nginx reverse proxy with SSL, firewall, swap, log rotation, and auto-tuned performance settings.

**What it does:** takes a fresh Ubuntu server and leaves you with Odoo running under systemd — dedicated system and PostgreSQL users, Python venv, patched wkhtmltopdf, tuned worker and memory limits, log rotation, and a firewall. Optionally Nginx with Let's Encrypt, a swap file, and nightly backups.

**What it does not do:** it does not install Odoo Enterprise, configure mail, set up replication or off-site backup copying, or manage the server after installation. It is a first-run installer, not a configuration-management tool — it will not reconcile a config you have since edited by hand.

## Features

- **Production-Ready**: Nginx reverse proxy, Let's Encrypt SSL, UFW firewall, logrotate, swap
- **Automated Backups**: Nightly Odoo-native zips (database + filestore in one file) via `click-odoo-backupdb`, ordered by activity, with retention cleanup
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

```bash
git clone https://github.com/abdalmola-apps/OdooInstallScript.git
cd OdooInstallScript
sudo ./odoo_install.sh
```

Then answer the prompts. Nothing is changed on the system until you confirm the summary.

### Install as a system command

If you deploy more than one server, put the three scripts on `PATH` once:

```bash
sudo make install
```

| Becomes | From |
|---------|------|
| `odoo-install` | `odoo_install.sh` |
| `odoo-nginx` | `odoo_nginx.sh` |
| `odoo-backup` | `odoo_backup.sh` |

They go in `/usr/local/bin`, with `requirements.txt` in `/usr/local/share/odoo-install/`. From then on, from any directory:

```bash
sudo odoo-install
sudo odoo-install -u odoo18 -y
sudo odoo-nginx -u odoo18 -d erp.mycompany.com -e admin@mycompany.com
sudo odoo-backup -u odoo18 -f
```

`odoo-install` finds its companions on `PATH`, so the repository no longer has to be present — or even checked out — after installing.

```bash
sudo make install PREFIX=/usr    # somewhere else
sudo make uninstall              # remove all four files
make check                       # shellcheck + bash -n
```

Running the scripts straight out of the checkout keeps working exactly as before; installing is optional.

### Express install

One command, no questions:

```bash
sudo ./odoo_install.sh -u odoo18 -y
```

Odoo 18.0 on the first free port from 8069, no Nginx, swap if RAM is under 4 GB, and daily backups at 02:00 with a 30-day retention. Good for a throwaway or a second instance; use the interactive run when you want Nginx and SSL.

### Options

| Flag | Meaning |
|------|---------|
| `-u <username>` | Odoo system user. Prompted for if omitted. |
| `-y` | Accept every default and skip the confirmation. Requires `-u`. |
| `-h` | Help. |

For an unattended install *with* Nginx or custom addons, pre-write the answers file — see [Unattended installs](#unattended-installs).

> **Clone the repository — do not download `odoo_install.sh` on its own.** The installer delegates the Nginx and backup steps to the other two scripts, and looks for them in its own directory first, then on `PATH` as `odoo-nginx` / `odoo-backup`. If you ask for a feature whose script is missing from both, it stops before making any changes and tells you.

## Which files do I need?

The three scripts are independent programs. Take only what you need:

| I want | Files needed | Run |
|--------|--------------|-----|
| Odoo only — no reverse proxy, no backups | `odoo_install.sh` | `sudo ./odoo_install.sh`, answer `no` to Nginx and backups |
| Odoo + Nginx + SSL | `odoo_install.sh`, `odoo_nginx.sh` | `sudo ./odoo_install.sh`, answer `yes` to Nginx |
| Odoo + backups | `odoo_install.sh`, `odoo_backup.sh`, `requirements.txt` | `sudo ./odoo_install.sh`, answer `yes` to backups |
| Everything | all of the above | `sudo ./odoo_install.sh` |
| Nginx + SSL for an Odoo I already have | `odoo_nginx.sh` | [Standalone Nginx Setup](#standalone-nginx-setup) |
| Backups for an Odoo I already have | `odoo_backup.sh` | [Automated Backups](#automated-backups) |

`requirements.txt` is optional for a bare install, but **required for backups** — it installs `click-odoo-contrib`, which `odoo_backup.sh` uses. The installer picks it up automatically when it sits beside `odoo_install.sh`.

`odoo_nginx.sh` and `odoo_backup.sh` are full command-line programs with their own `-h` output. Neither imports anything from `odoo_install.sh`, so both work on servers this installer never touched.

## Interactive Prompts

The script prompts for the following (with validation and defaults):

| Prompt | Default | Validation |
|--------|---------|------------|
| System username | *(required)* | Alphanumeric + underscore |
| Odoo version | `18.0` | Pick from a menu of the current release branches, or type any version — checked against `odoo/odoo` before the install starts |
| HTTP port | *first free pair from `8069`* | Range 1024-65535, and both the port and the one above it must be free |
| Install Nginx? | `no` | yes/no |
| Domain name | *(required if Nginx)* | Valid FQDN, and its DNS is checked against this server before anything is installed — see [DNS check](#dns-check) |
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
Available Odoo versions:
  1) 19.0
  2) 18.0   (default)
  3) 17.0
  4) 16.0

Select a number, or type any version [18.0]: 2
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

The script performs 20 automated steps:

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
| 20 | Create the first database *(conditional)* |

## What Gets Installed

### System Packages
- PostgreSQL and postgresql-contrib
- Python 3 development tools (python3-dev, python3-venv, python3-wheel, python3-setuptools)
- Build tools (build-essential, git, wget, curl)
- Required libraries (libxslt-dev, libzip-dev, libldap2-dev, libsasl2-dev, libpq-dev, libpng-dev, libjpeg-dev)
- Node.js, npm, LESS, rtlcss
- wkhtmltopdf (patched Qt version, release auto-selected for your OS — see below)
- UFW firewall
- Nginx + Certbot *(optional)*

### Python Packages (in virtual environment)
- All packages from Odoo's `requirements.txt`
- num2words, ofxparse, dbfread, ebaysdk, firebase_admin, pyOpenSSL
- Additional packages from this repository's `requirements.txt` (if present)

## First Database

`list_db = False` hides Odoo's database manager, so there is no way to create the first database from a browser. Step 20 creates it instead — otherwise the install finishes with a running server nobody can log into.

| Prompt | Effect |
|--------|--------|
| Create the first database now? | `no` leaves it to you; the final summary prints the command |
| Database name | Defaults to the system username |
| Production or demo? | `prod` never loads demo data — it cannot be removed cleanly afterwards |
| Load demo data? | Only asked for `demo` |

The database is created with `base` installed, then the `admin` password is replaced with a random one and printed in the final summary. Odoo ships `admin`/`admin`, which is not something to leave on a server that is about to be reachable.

Two different passwords end up in that summary:

- **Master password** — `admin_passwd` in the config. Guards database management operations. Not a login.
- **Login** — `admin` plus the generated password. This is what you sign in with.

Re-running is safe: if the database already exists the step is skipped rather than recreated.

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

- Upstream blocks for Odoo HTTP and websocket/longpolling, named per user (`<user>_odoo`, `<user>_gevent`) so multiple instances coexist
- WebSocket support (`/websocket` location with upgrade headers)
- Longpolling proxy (`/longpolling`)
- Static file caching for every module (`/<module>/static/`, 24h expiry)
- Gzip compression on text types
- Proper proxy headers (`X-Forwarded-Host`, `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Real-IP`)
- Security headers: HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`
- `client_max_body_size 200m`
- Let's Encrypt SSL via Certbot with forced HTTP→HTTPS redirect, HTTP/2, and auto-renewal verified

### DNS check

A domain that does not point at the server is the usual reason SSL fails, and Let's Encrypt rate-limits **failed validations to 5 per hostname per hour** — so two careless retries cost you an hour. The installer checks this straight after the prompts, before a single package is installed:

```
[WARN] erp.mycompany.com resolves to: 198.51.100.7
[WARN] None of those is this server: 10.0.0.5 203.0.113.9

  Add this record at your DNS provider, then choose [r]:

      Type   A
      Name   erp.mycompany.com
      Value  203.0.113.9
      TTL    300  (or the lowest offered)

  [r] re-check  [d] different domain  [c] continue anyway  [s] skip Nginx:
```

| Choice | What happens |
|--------|--------------|
| `r` | Re-resolves the same domain. Add the A record in another tab, wait, press `r`. At TTL 300 it is usually live in under 5 minutes. |
| `d` | Type a different domain and check that one instead. |
| `c` | Proceed anyway. **The right answer behind Cloudflare's proxy (orange cloud), a load balancer, or NAT** — the addresses are supposed to differ there. If certbot then fails, the site stays on plain HTTP and the command to retry is printed. |
| `s` | Drop Nginx and SSL from this run. Odoo is reachable at `http://<server-ip>:<port>`; run `odoo_nginx.sh` later once DNS is ready. |

The server's own address is taken from `hostname -I` **plus** its public IP (via `api.ipify.org`), because on a cloud VM behind 1:1 NAT — AWS, GCP, Azure — `hostname -I` only reports a private address and every domain would look mispointed. If that lookup fails the check still runs against local addresses only.

Running `odoo_nginx.sh` standalone performs the same check and asks once before spending a certificate attempt. Pass `-y` to skip that question.

## Automated Backups

When backups are enabled during installation, the script installs `odoo_backup.sh` and a cron job that runs daily at 2:00 AM.

### What It Does

1. Discovers all PostgreSQL databases owned by the Odoo user
2. Queries each database for the latest `write_date` from `res_users`
3. Sorts databases by activity (most recently used first)
4. Backs each one up with `click-odoo-backupdb` as a single Odoo-native zip
5. Cleans up backups older than the retention period (default: 30 days)

Exits non-zero if any database fails, so cron surfaces the failure instead of a backup job that silently does nothing every night.

### Backup Files

- **Backups**: `<dbname>_<timestamp>.zip` — `manifest.json` + `dump.sql` + `filestore/`, deflate-compressed with zip64 (no 4 GB limit)
- **Log**: `/home/<username>/data/backup.log`

The zip is the same layout Odoo's own database manager produces, so it restores through the web interface as well as from the CLI. Requires `click-odoo-contrib` in the instance venv — this repo's `requirements.txt` installs it.

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

Database and filestore restore together in one command:

```bash
sudo -u <username> /home/<username>/odoo/venv/bin/click-odoo-restoredb \
    -c /home/<username>/<username>-odoo.conf \
    <new_dbname> /home/<username>/backups/<dbname>_<timestamp>.zip
```

Useful flags:

| Flag | Effect |
|------|--------|
| `--neutralize` | Disables scheduled actions and outgoing mail — always use this for staging or dev copies |
| `--force` | Overwrite `<new_dbname>` if it already exists |
| `--copy` / `--move` | `--copy` (default) regenerates the database UUID so the restore does not conflict with the original |

The zip also uploads through Odoo's own database manager (`/web/database/manager`) if you prefer the web interface — note `list_db = False` hides it by default.

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
| `-y` | Never prompt — request the certificate even if the domain does not resolve here. `odoo_install.sh` passes this because it runs the same check up front | off |
| `-h` | Show help | — |

### What It Does

1. Installs Nginx, Certbot, and python3-certbot-nginx
2. Writes the Nginx site config (per-user upstreams, WebSocket support, static caching, gzip, security headers)
3. Enables the site, removes the default site, tests and reloads Nginx — unlinking the site again if the test fails
4. Checks the domain resolves to this server before spending a Let's Encrypt attempt (rate-limited to 5 failures/hostname/hour)
5. Requests the certificate with `--redirect --keep-until-expiring`, then enables HTTP/2 and confirms `certbot.timer` is armed
6. Sets `proxy_mode = True` in the Odoo config, restarting the service if it is already running

## wkhtmltopdf Auto-Detection

Upstream archived wkhtmltopdf in 2023, so the published builds are now fixed — and there is no build for every Ubuntu release. The script picks the combination that actually exists:

| Ubuntu | Codename | Release used | Build |
|--------|----------|--------------|-------|
| 20.04 | focal | `0.12.6-1` | `focal` — later releases dropped focal amd64/arm64 |
| 22.04 | jammy | `0.12.6.1-3` | `jammy` |
| 24.04 | noble | `0.12.6.1-3` | `jammy` — no noble build exists |
| other | — | `0.12.6.1-3` | `jammy` (with a warning) |

Architectures: `amd64`, `arm64`.

The jammy package installs cleanly on 24.04 despite the `t64` library rename: noble's `libssl3t64` and `libpng16-16t64` declare `Provides:` for the names it depends on, and `libjpeg-turbo8` is unchanged.

If the download 404s, the script reports the exact URL and stops rather than failing with a bare `wget` exit code. An already-installed wkhtmltopdf is checked for the patched-Qt build and warns if it is the unpatched apt version.

### Why the Patched Version?

The standard `apt` version uses an unpatched Qt library that doesn't support `--header-spacing`, `--header-html`, and `--footer-html` — required for proper PDF rendering in Odoo.

## Checkpoint System

The script saves both its progress and your answers to `/var/lib/odoo-install/` (root-only, `chmod 700`):

| File | Contents |
|------|----------|
| `<username>.checkpoint` | Last completed step number |
| `<username>.answers` | The answers to all 11 prompts |

### Resuming an interrupted install

```bash
sudo ./odoo_install.sh
```

1. Enter **the same username** — it is the key for the saved state, so it is the one question always asked.
2. Answer `yes` to *"Reuse its answers and skip the questions?"* — the other ten prompts are skipped.
3. Check the summary and confirm.

Completed steps are skipped and the install continues from where it stopped. Answering `no` at step 2 re-asks everything instead.

On failure the error handler prints the failed step, the resume instructions, and the state file path. Both state files are deleted on successful completion.

Because the state lives under `/var/lib` rather than `/tmp`, a resume survives a reboot.

### Unattended installs

Write the answers file yourself and the script will only ask for confirmation:

```bash
sudo mkdir -p /var/lib/odoo-install && sudo chmod 700 /var/lib/odoo-install
sudo tee /var/lib/odoo-install/odoo18.answers > /dev/null <<'EOF'
OE_VERSION=18.0
OE_PORT=8069
INSTALL_NGINX=yes
OE_DOMAIN=erp.example.com
CERTBOT_EMAIL=admin@example.com
CUSTOM_ADDONS_INPUT=https://github.com/OCA/web.git
SETUP_SWAP=yes
SETUP_BACKUP=yes
BACKUP_FILESTORE=yes
BACKUP_RETENTION=30
BACKUP_HOUR=02:00
EOF
sudo chmod 600 /var/lib/odoo-install/odoo18.answers
```

The file is sourced as root, which is why the directory must not be world-writable.

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

## Version Selection

The menu is built at runtime from the branches that exist in `github.com/odoo/odoo`, so it stays correct as Odoo releases rather than drifting against a hardcoded list. Type a number to pick one, or type any version directly — `14.0` and older still work, they are just not listed.

Each version is labelled with whether it can actually run on **this** server:

```
Available Odoo versions   (this server: Ubuntu noble, Python 3.12)
  1) 19.0   (needs Python >= 3.10 — OK here)
  2) 18.0   (needs Python >= 3.10 — OK here, default)
  3) 17.0   (needs Python >= 3.10 — OK here)
  4) 16.0   (needs Python >= 3.7 — OK here)
```

On an Ubuntu 20.04 box the same menu marks 17.0 and newer as *NOT usable* and switches the default to the newest version that runs there. Odoo versions and Python versions have to line up in both directions:

| Check | Source | Effect |
|-------|--------|--------|
| Python too **old** for the Odoo version | `MIN_PY_VERSION` in Odoo's own source | Refused — Odoo asserts on it at import and would never start |
| Python too **new** for the Odoo version | highest `python_version` marker in that branch's `requirements.txt` | Warned, with a confirm — it would start, but step 6 has to build pinned wheels that were never published for an interpreter that new |

The second case is the one that bites when installing an older Odoo on a current Ubuntu: 14.0's requirements stop at Python 3.9, so on 22.04 (3.10) or 24.04 (3.12) the `pip install` step fails compiling gevent. The script now says so at the prompt instead of after four steps of system changes.

Odoo moved where it declares its minimum — `odoo/release.py` in 19.0+, `odoo/__init__.py` in 15.0–18.0, and a bare `assert` in 14.0 and older — so all three are checked.

A typo is caught here too: `23.0` passes the `XX.0` format check and used to fail at step 4, after the system and database users had been created. If GitHub is unreachable the script falls back to a built-in list and skips these checks.

## Port Selection

Odoo needs two consecutive ports — HTTP, and the websocket port directly above it. The installer offers the lowest free pair starting at `8069`, and rejects a port you type in if either half is taken.

A port counts as taken when:

- something is listening on it (`ss`), **or**
- another instance's config claims it — checked across `/home/*/*-odoo.conf`

The second test is the one that matters for multi-instance servers: a *stopped* instance still owns its port, and it would collide the moment both were running. Nothing checked this before, and a collision surfaced only as a service that refused to start after the installer had already reported success.

## Multiple Instances

Run the script again with a different username. The port is picked for you. Each instance gets its own:
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

All three scripts are released under the **GNU Lesser General Public License v3.0**, matching Odoo's own licence.

- [`COPYING.LESSER`](COPYING.LESSER) — the LGPL-3.0 terms
- [`COPYING`](COPYING) — the GPL-3.0 text that the LGPL builds on

Both files are needed: the LGPL is a set of additional permissions layered on the GPL, so it incorporates the GPL by reference rather than restating it. The two-file `COPYING` / `COPYING.LESSER` split is the FSF's own convention.

## Author

**abdalmola**

Production-grade Odoo deployment automation for system administrators and DevOps engineers.
