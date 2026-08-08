# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Eight standalone Bash scripts that deploy and manage production Odoo on Ubuntu (20.04/22.04/24.04), plus `abo`, a dispatcher that fronts them. No build, no CI. `make check` is shellcheck + `bash -n` + the `tests/*_t.sh` self-checks — small assert scripts covering logic that cannot be exercised without a live server, not a suite. `requirements.txt` is payload — extra Python packages installed into the target server's venv, not this repo's deps.

**`abo` is a dispatcher and nothing else.** It resolves `LIBDIR` (its own directory in a checkout, `../lib/abo` when installed) and `exec`s `odoo_<cmd>.sh` with every argument passed through untouched. Never put logic in it — each subcommand script must keep working when run directly, which is what the "Which files do I need?" table in the README promises. Adding a subcommand is one `case` arm plus one line in the Makefile's `SCRIPTS`.

The `Makefile` installs `abo` to `<prefix>/bin` and the scripts to `<prefix>/lib/abo`. Co-locating them there is what makes `find_companion` work unchanged in both layouts. `install` also removes the `odoo-install`/`odoo-nginx`/`odoo-backup` commands from 2.3.0 and the old `share/odoo-install` directory; drop that cleanup once nobody is upgrading across it.

## Commands

```bash
make check                                                 # shellcheck + bash -n + tests/*_t.sh
bash -n odoo_install.sh                                    # syntax-only parse

# The scripts mutate a live system (apt, systemd, ufw, /etc/fstab, crontab).
# Never run odoo_install.sh on the dev machine — test in a throwaway VM/container.

# Sub-scripts are independently runnable and are the fast path for testing changes:
sudo ./odoo_nginx.sh  -u <user> -d <fqdn> -e <email> [-p 8069] [-l 8070]
sudo ./odoo_backup.sh -u <user> [-d <dir>] [-r 30] [-f] [-q]
```

## Architecture

**`odoo_install.sh` is the orchestrator.** It resolves `SCRIPT_DIR` from `BASH_SOURCE` and shells out to `odoo_nginx.sh` (step 15) and `odoo_backup.sh` (step 19, copied to `$OE_HOME/` and cron'd). The installer hard-fails on a missing `odoo_nginx.sh` and warn-skips a missing `odoo_backup.sh`.

**Two supported layouts, one resolver.** `find_companion <file> <command>` checks `$SCRIPT_DIR/<file>` (git checkout) then `command -v <command>` (installed via `make install` as `odoo-nginx` / `odoo-backup`); `find_data_file` does the same for `requirements.txt`, falling back to `$SCRIPT_DIR/../share/odoo-install/` so it stays correct under any `PREFIX` or `DESTDIR`. Both print the resolved path and return 1 when nothing matches — every call site goes through them, so never reintroduce a bare `$SCRIPT_DIR/odoo_*.sh` test. The `Makefile` renames on install (`odoo_install.sh` → `odoo-install`), which is exactly why the lookup cannot key on filename alone.

A resolved path is readable by *root*, not necessarily by `$OE_USER` — a checkout under `/root` (mode 700) is not. Step 6 therefore stages `requirements.txt` into `$OE_HOME` before handing it to pip, which runs as `$OE_USER`. Anything else fed to an `sudo -u "$OE_USER"` command from outside `$OE_HOME` needs the same treatment.

**`$OE_USER` is the single namespace key.** Everything derives from it: `/home/$OE_USER`, `${OE_USER}-odoo.conf`, `${OE_USER}-odoo.service`, the PostgreSQL role, `/etc/logrotate.d/${OE_USER}-odoo`, nginx log names, `/tmp/odoo_setup_checkpoint_${OE_USER}`. Multi-instance support is entirely this convention — don't introduce a fixed path or name anywhere.

**Checkpoint/resume.** `step N "desc"` returns 0 to run, 1 to skip when `N <= LAST_CHECKPOINT`; each block ends with `save_checkpoint N`. Consequences:
- Step numbers are a persisted interface. Renumbering or inserting a step mid-sequence corrupts resume for interrupted installs — append new steps at the end.
- Every step body must be idempotent on its own (existence checks before create), because a step can re-run after a mid-step crash.

State lives in `/var/lib/odoo-install/<user>.{checkpoint,answers}`, root-owned in a 700 directory — not `/tmp`, because the answers file is `source`d as root and a world-writable location would be a local privilege escalation. A pre-2.2 `/tmp/odoo_setup_checkpoint_<user>` is migrated on sight.

**Ports are auto-selected, not fixed.** `find_free_port` returns the lowest pair where both `p` and `p+1` are free; `port_in_use` checks listening sockets *and* `/home/*/*-odoo.conf` claims, because a stopped instance still owns its port. The config grep needs `sudo` — instance configs are `chmod 640` owned by their own user. Typed ports go through the same check.

**Three input paths, not two:** `REUSE_ANSWERS` (saved answers), `EXPRESS` (`-y`, all defaults, skips the confirmation), and the interactive prompts. They are branches of one `if/elif/else`; a new prompt needs a default in the express branch and an entry in `save_answers()`, or it silently reverts.

**The prompt block is wrapped in `if [ "$REUSE_ANSWERS" = "yes" ] … else … fi`,** closed by a lone `fi` marked with a comment. Anything a *reused* run also needs (currently `RAM_MB` and the `VALID_ADDON_URLS` parsing) must sit after that `fi`, not inside the prompt branch — the answers file stores the raw `CUSTOM_ADDONS_INPUT` string, not the parsed array. Adding a prompt means adding the variable to `save_answers()` too, or it silently reverts to its default on resume.

**Config-file contract between scripts.** `odoo_install.sh` step 11 writes `$OE_HOME/${OE_USER}-odoo.conf` including a literal `; Security` comment line; `odoo_nginx.sh` step 5 patches `proxy_mode` by looking for `^proxy_mode`, falling back to inserting after `^; Security`. Changing that comment or the key's default breaks the standalone nginx path silently.

The websocket port key is version-conditional (`$GEVENT_KEY`): `gevent_port` on Odoo 16+, `longpolling_port` below. It must stay in sync with the `/websocket` upstream in `odoo_nginx.sh`, which proxies to `OE_PORT + 1` — writing the wrong key leaves Odoo on its 8072 default and breaks websockets with no error in the log.

**Nginx names are namespaced by `$OE_USER`** (`<user>_odoo`, `<user>_gevent`, `$<user>_conn_upgrade`). `upstream` and `map` live in the shared `http{}` scope, so a second instance reusing a generic name makes nginx refuse to start and takes the first site down with it. Never introduce a fixed name in that heredoc.

**DNS is gated before mutation, not at step 15.** `odoo_install.sh` runs a `while [ "$INSTALL_NGINX" = "yes" ]` loop right after the prompt block's closing `fi` — so it covers all three input paths (express sets `INSTALL_NGINX=no`, so it no-ops there). `check_domain_dns` returns 0/1/2 (points here / elsewhere / no record) and leaves the addresses in `DNS_RESOLVED_IPS`. `server_ips` unions `hostname -I` with the public IP from `api.ipify.org`, because cloud VMs sit behind 1:1 NAT and local-only comparison false-positives on every one of them. The `s` branch flips `INSTALL_NGINX` to `no` and blanks the domain/email, which is why the gate must stay *above* `save_answers` and the companion-script check.

`odoo_nginx.sh` repeats the check standalone and prompts before spending a certificate attempt; `odoo_install.sh` passes `-y` to suppress that second question. `SSL_STATUS` is assigned in all three certbot branches (skipped / issued / failed) and drives both the summary line and the printed URL scheme — a summary that says `https://` after certbot failed sends people to a closed port. `odoo_install.sh` decides the same thing independently, by testing `/etc/letsencrypt/live/$OE_DOMAIN`, because `odoo_nginx.sh` runs as a subprocess and reports nothing back.

**Step 18 waits for the socket, not for systemd.** `systemctl start` returns once the process is forked, so it exits 0 for an Odoo that dies a second later. The step polls `ss` for up to 60s and warns loudly if the port never opens. It deliberately does *not* use `port_in_use()` — that helper also counts a config-file claim, and step 11 just wrote a config claiming this port, so it would pass unconditionally.

**`server_name` and the certbot `-d` list must always agree.** `odoo_nginx.sh` builds `SERVER_NAMES` and `CERT_DOMAINS` from the same `WWW_DOMAIN` decision for exactly this reason — a name served but not covered is the "Not secure" bug, and the Odoo site is the only enabled site, hence the default server, so any pointed hostname reaches it whether or not it is listed. `www.<domain>` is added only when `resolves_here` confirms it points at this box: one failing `-d` fails the whole certificate request, so an unused www record would cost SSL entirely. Never add a name to one list without the other.

Certbot is invoked `--redirect --keep-until-expiring --expand` — the first because the default has moved between releases, the second so re-runs don't reissue and burn the 5-duplicates-per-week limit, the third so a `www` record added after the fact is picked up on a re-run instead of certbot refusing non-interactively when the domain set grows. HTTP/2 is patched in afterwards with a `sed` over the `listen …443 ssl` lines (certbot never enables it); the edit is idempotent and reverted if `nginx -t` fails.

**apt is always called through `apt_get()`** (`odoo_install.sh`) or `APT_OPTS` (`odoo_nginx.sh`): `DPkg::Lock::Timeout=600` so unattended-upgrades holding the dpkg lock on a fresh server waits instead of aborting the run, plus noninteractive debconf/needrestart. Never call bare `apt-get`/`apt`.

**Two root models.** `odoo_install.sh` runs as an unprivileged user and prefixes each privileged call with `sudo`. `odoo_nginx.sh` enforces `id -u` = 0 and calls tools directly. `odoo_backup.sh` needs root only because it does `sudo -u postgres` / `sudo -u $OE_USER`. Match the surrounding style when editing.

**Duplicated validators are deliberate.** `validate_username` / `validate_port` exist in both `odoo_install.sh` and `odoo_nginx.sh` so each stays a single self-contained downloadable file. Don't factor them into a shared lib.

**Input flow.** All prompts + the confirmation summary run before any system mutation. Prompts loop until valid (except the addon-URL list, which exits 1 on a bad URL). Keep new prompts in that pre-mutation block.

**Timezone and swap size are answers, not constants.** `OE_TIMEZONE` defaults to the server's own zone (`system_timezone`) rather than a hardcoded one, and reaches both `timedatectl set-timezone` and a psql string literal — so `validate_timezone` gates it at the prompt *and* again after the answers file is sourced, since a hand-written answers file is a documented workflow. `SWAP_SIZE_MB` is capped at 10% of `/` (`max_swap_mb`) because swap shares that disk with the database and filestore; a cap under 512MB turns swap off instead of creating a useless file. Both sit in `save_answers()` and both have a `${VAR:-}` fallback after the prompt block's closing `fi`, so an answers file written before they existed still resumes.

**Logs live in `$OE_LOG_DIR` (`/home/$OE_USER/logs`), never in `$OE_DATA_DIR`.** The data dir holds the filestore and sessions, so the logrotate rule globs `$OE_LOG_DIR/*.log` — one rule covering `odoo-server.log` and the backup cron's `backup.log` both. Anything new that writes a log belongs in that directory and needs no rule of its own. Step 14 re-creates the directory before writing the rule because a resume can start past step 8. Step 21 handles the other two logs on the box by editing `/etc/logrotate.d/{nginx,postgresql-common}` in place — the per-instance Nginx logs are already inside the distro's `/var/log/nginx/*.log` glob, so a separate rule would just produce a duplicate-entry error. The substitution targets a bare interval keyword alone on its line (`hourly|daily|monthly|yearly` → `weekly`), which is why it is idempotent and cannot touch a `daily` inside a `prerotate` script. `odoo_status.sh` and `odoo_update.sh` read the log path back out of the config rather than assuming it, so instances installed before this directory existed still get a correct hint.

**`odoo_logs.sh` migrates instances that predate that directory,** and is the only script that rewrites another script's output. Report by default, act on `-m` — same shape as `odoo_ssl.sh`. It migrates only when `dirname(logfile)` is exactly `/home/$OE_USER/data`: a logfile anywhere else is an operator's choice and is left alone. The move is `mv` within `/home/$OE_USER`, i.e. `rename(2)`, so a running Odoo's open descriptor follows the file and no restart is needed — which holds only within one filesystem, hence the `stat -c %d` comparison that aborts instead of letting a copy-and-unlink leave Odoo writing to an unlinked inode. `find -maxdepth 1` keeps the filestore under `data/` out of scope. `sed -i` writes a new file and renames it over the config, so the `chown`/`chmod 640` afterwards is not redundant. The backup redirect lives in *root's* crontab and is rewritten by exact path, never by regenerating the line.

**Auto-tuning** (derived-variables block, ~line 293): `workers = min(cores*2+1, RAM_MB/256)` floored at 2; soft memory limit = 80% RAM split across `workers + cron + 1`; hard = soft*1.2; `db_maxconn = workers*2+4`. Values land in both the config file and the summary output — update both.

**`odoo_update.sh` must never unshallow or clean.** The installer clones `--depth 1`, so the update fetches `--depth 1` too; unshallowing pulls ~2GB nobody asked for. It uses `git reset --hard FETCH_HEAD` and never `git clean` — the venv sits at `$OE_HOME_EXT/venv`, inside the work tree but untracked, so a clean would delete the interpreter mid-update. Requirements are reinstalled only when `sha256sum requirements.txt` differs across the reset. `-m` (`odoo-bin -u all`) stops the service first and hard-fails if no `odoo_backup.sh` can be found, because module-data upgrades are not reversible.

**`odoo_status.sh` must stay cheap.** It is meant to be run on a whim and from cron, so every check is an O(1) query — `df`, `stat`, `pg_database_size()`, `ss`. Never add a `du` over the filestore or a `find` across the home directory. It discovers instances by globbing `/home/*/*-odoo.conf` and matching the path back exactly, so a stray file cannot invent an instance. It reports a certificate's expiry but deliberately does *not* repeat `odoo_ssl.sh`'s SAN-vs-`server_name` diff — one place for that check. Exit status is the interface: non-zero means something needs attention, so anything new that prints a warning must also count into `PROBLEMS`.

**`odoo_ssl.sh` is a reporter, not a renewal implementation.** `certbot.timer` already renews; the script wraps `certbot renew` and exists for the report. Its one non-wrapper check is `comm -23` of the site's `server_name` against the certificate's SANs — the mismatch that produces "Not secure" while every automated component reports success. It resolves `-u` to a domain the same way `odoo_remove.sh` finds the site (grep `sites-available` for `upstream ${OE_USER}_odoo`), and matches a domain to a lineage by reading the SANs rather than trusting the directory name, since certbot appends `-0001` on a collision. `certbot renew --cert-name` takes one lineage and the last flag wins, so a scoped run loops one certbot call per certificate — never build a repeated-flag argument array there.

**`odoo_remove.sh` is the only destructive script.** Order matters and is deliberate: inventory → role-blocker check → plan → typed confirmation → backup → service → nginx → cron → databases → role → logrotate → state → UFW → `userdel -r` last, so a failure anywhere earlier still leaves the data on disk.

Role removal is gated twice, and both gates *stop* rather than warn. The predictive one queries `pg_shdepend` at inventory time for objects the role owns in databases whose `datdba` is not that role — i.e. anything outside the set being dropped — and aborts before a single change. The authoritative one is `dropuser`'s own exit status, which aborts before `userdel`, so the account and home survive a failure and the operator can reassign ownership and re-run. Never downgrade either to a warning: a PostgreSQL role outliving its Unix account is an orphan nobody goes looking for. It refuses non-interactive stdin, refuses a hardcoded list of system accounts, and refuses an account with neither `$OE_HOME/${OE_USER}-odoo.conf` nor `${OE_USER}-odoo.service` — never a UID-range test, because the installer's `adduser --system` puts every legitimate instance below 1000. It finds the Nginx site by grepping `sites-available` for `upstream ${OE_USER}_odoo` rather than guessing the filename, since sites are named after the domain. Backups go to `/root/abo-removed` with `-r 36500` so the retention sweep cannot prune the last remaining copy. TLS certs are intentionally left in place.

**Backup selection logic.** Databases are discovered by PostgreSQL ownership (`pg_database.datdba` = the `$OE_USER` role), then ordered by `MAX(write_date)` from `res_users` so the most active DB dumps first; non-Odoo DBs fall back to epoch and sort last. Dumps are `click-odoo-backupdb --format zip` (one Odoo-native zip per database, restorable through the web UI); retention prunes by `find -mtime`, still globbing the pre-click-odoo `*.dump`/`*.tar.gz` so older backups age out too.

**Odoo is never pip-installed into the venv,** so `import odoo` resolves only from the source tree. The systemd unit gets that from `WorkingDirectory=$OE_HOME_EXT`; anything else invoking a `click-odoo-*` entry point runs from the caller's cwd — cron's, or wherever the operator stood — and must pass `PYTHONPATH=$OE_HOME/odoo` or die in `click_odoo/compat.py` before doing any work. It goes through `sudo -u "$OE_USER" -H env PYTHONPATH=…`, not `sudo VAR=value`, which sudoers rejects without `SETENV`. The documented `click-odoo-restoredb` command in the README and in `odoo_backup.sh`'s `-h` text carries it for the same reason.

## Conventions

- `set -euo pipefail` in all three; `log_info/warn/error/success` helpers with color constants; a boxed summary block at the end of each script.
- `odoo_install.sh` traps `ERR INT TERM` and reports the failed step number plus the checkpoint path — keep `CURRENT_STEP` accurate if you add steps.
- Sub-scripts take short getopts flags with `-h` usage text; keep flag names stable, `odoo_install.sh` passes them positionally-by-flag.
- Anything user-facing that changes (new prompt, new flag, new step) belongs in `README.md` too — it documents the prompt table, the 19-step table, and both flag tables.
