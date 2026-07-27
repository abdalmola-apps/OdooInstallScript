# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Three standalone Bash scripts that deploy production Odoo on Ubuntu (20.04/22.04/24.04). No build, no test suite, no CI. `requirements.txt` is payload — extra Python packages installed into the target server's venv, not this repo's deps.

## Commands

```bash
shellcheck odoo_install.sh odoo_nginx.sh odoo_backup.sh   # only available checker
bash -n odoo_install.sh                                    # syntax-only parse

# The scripts mutate a live system (apt, systemd, ufw, /etc/fstab, crontab).
# Never run odoo_install.sh on the dev machine — test in a throwaway VM/container.

# Sub-scripts are independently runnable and are the fast path for testing changes:
sudo ./odoo_nginx.sh  -u <user> -d <fqdn> -e <email> [-p 8069] [-l 8070]
sudo ./odoo_backup.sh -u <user> [-d <dir>] [-r 30] [-f] [-q]
```

## Architecture

**`odoo_install.sh` is the orchestrator.** It resolves `SCRIPT_DIR` from `BASH_SOURCE` and shells out to `odoo_nginx.sh` (step 15) and `odoo_backup.sh` (step 19, copied to `$OE_HOME/` and cron'd). All three files must stay co-located; the installer hard-fails on a missing `odoo_nginx.sh` and warn-skips a missing `odoo_backup.sh`.

**`$OE_USER` is the single namespace key.** Everything derives from it: `/home/$OE_USER`, `${OE_USER}-odoo.conf`, `${OE_USER}-odoo.service`, the PostgreSQL role, `/etc/logrotate.d/${OE_USER}-odoo`, nginx log names, `/tmp/odoo_setup_checkpoint_${OE_USER}`. Multi-instance support is entirely this convention — don't introduce a fixed path or name anywhere.

**Checkpoint/resume.** `step N "desc"` returns 0 to run, 1 to skip when `N <= LAST_CHECKPOINT`; each block ends with `save_checkpoint N`. Consequences:
- Step numbers are a persisted interface. Renumbering or inserting a step mid-sequence corrupts resume for interrupted installs — append new steps at the end.
- Every step body must be idempotent on its own (existence checks before create), because a step can re-run after a mid-step crash.

**Config-file contract between scripts.** `odoo_install.sh` step 11 writes `$OE_HOME/${OE_USER}-odoo.conf` including a literal `; Security` comment line; `odoo_nginx.sh` step 5 patches `proxy_mode` by looking for `^proxy_mode`, falling back to inserting after `^; Security`. Changing that comment or the key's default breaks the standalone nginx path silently.

The websocket port key is version-conditional (`$GEVENT_KEY`): `gevent_port` on Odoo 16+, `longpolling_port` below. It must stay in sync with the `/websocket` upstream in `odoo_nginx.sh`, which proxies to `OE_PORT + 1` — writing the wrong key leaves Odoo on its 8072 default and breaks websockets with no error in the log.

**Nginx names are namespaced by `$OE_USER`** (`<user>_odoo`, `<user>_gevent`, `$<user>_conn_upgrade`). `upstream` and `map` live in the shared `http{}` scope, so a second instance reusing a generic name makes nginx refuse to start and takes the first site down with it. Never introduce a fixed name in that heredoc.

Certbot is invoked `--redirect --keep-until-expiring` — the first because the default has moved between releases, the second so re-runs don't reissue and burn the 5-duplicates-per-week limit. HTTP/2 is patched in afterwards with a `sed` over the `listen …443 ssl` lines (certbot never enables it); the edit is idempotent and reverted if `nginx -t` fails.

**apt is always called through `apt_get()`** (`odoo_install.sh`) or `APT_OPTS` (`odoo_nginx.sh`): `DPkg::Lock::Timeout=600` so unattended-upgrades holding the dpkg lock on a fresh server waits instead of aborting the run, plus noninteractive debconf/needrestart. Never call bare `apt-get`/`apt`.

**Two root models.** `odoo_install.sh` runs as an unprivileged user and prefixes each privileged call with `sudo`. `odoo_nginx.sh` enforces `id -u` = 0 and calls tools directly. `odoo_backup.sh` needs root only because it does `sudo -u postgres` / `sudo -u $OE_USER`. Match the surrounding style when editing.

**Duplicated validators are deliberate.** `validate_username` / `validate_port` exist in both `odoo_install.sh` and `odoo_nginx.sh` so each stays a single self-contained downloadable file. Don't factor them into a shared lib.

**Input flow.** All prompts + the confirmation summary run before any system mutation. Prompts loop until valid (except the addon-URL list, which exits 1 on a bad URL). Keep new prompts in that pre-mutation block.

**Auto-tuning** (derived-variables block, ~line 293): `workers = min(cores*2+1, RAM_MB/256)` floored at 2; soft memory limit = 80% RAM split across `workers + cron + 1`; hard = soft*1.2; `db_maxconn = workers*2+4`. Values land in both the config file and the summary output — update both.

**Backup selection logic.** Databases are discovered by PostgreSQL ownership (`pg_database.datdba` = the `$OE_USER` role), then ordered by `MAX(write_date)` from `res_users` so the most active DB dumps first; non-Odoo DBs fall back to epoch and sort last. Dumps are `pg_dump -Fc -Z5`; retention prunes by `find -mtime`.

## Conventions

- `set -euo pipefail` in all three; `log_info/warn/error/success` helpers with color constants; a boxed summary block at the end of each script.
- `odoo_install.sh` traps `ERR INT TERM` and reports the failed step number plus the checkpoint path — keep `CURRENT_STEP` accurate if you add steps.
- Sub-scripts take short getopts flags with `-h` usage text; keep flag names stable, `odoo_install.sh` passes them positionally-by-flag.
- Anything user-facing that changes (new prompt, new flag, new step) belongs in `README.md` too — it documents the prompt table, the 19-step table, and both flag tables.
