#!/bin/bash
# Check for odoo_remove.sh's instance-evidence guard.
#
# Evaluates the guard block extracted from the real script — only the
# /etc/systemd/system prefix is rewritten into a fixture root, so the test can
# run unprivileged. Everything else is the shipped text.
set -euo pipefail

SRC="${1:-$(dirname "$0")/../odoo_remove.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

GUARD="$(awk '/^# The UID says nothing/,/^fi$/' "$SRC" \
         | sed "s|/etc/systemd/system/|$T/etc/systemd/system/|")"

[ -n "$GUARD" ] || { echo "FAIL: guard block not found in $SRC"; exit 1; }
grep -q 'odoo\.conf' <<<"$GUARD"    || { echo "FAIL: guard lost the config check"; exit 1; }
grep -q 'OE_SERVICE' <<<"$GUARD"    || { echo "FAIL: guard lost the service check"; exit 1; }
if grep -qE '\-lt 1000' "$SRC"; then echo "FAIL: UID-range guard is back"; exit 1; fi

mkdir -p "$T/etc/systemd/system" "$T/home/hdtrading" "$T/home/odoo18" "$T/home/games"

# hdtrading: real instance, UID 108 from `adduser --system` — the reported bug.
touch "$T/home/hdtrading/hdtrading-odoo.conf"
# odoo18: home wiped by a half-finished removal, unit still there.
touch "$T/etc/systemd/system/odoo18-odoo.service"
# games: a distro account. Neither artefact.

fails=0
run() {  # run <user> <expected: pass|refuse>
    local u="$1" want="$2" got=pass out
    # shellcheck disable=SC2034  # read by the guard, which runs under eval
    OE_USER="$u" OE_HOME="$T/home/$u" OE_SERVICE="${u}-odoo.service"
    log_error() { :; }
    out="$(eval "$GUARD" 2>&1)" || got=refuse
    if [ "$got" != "$want" ]; then
        echo "FAIL: $u -> $got, expected $want ${out:+($out)}"
        fails=$((fails + 1))
    else
        echo "ok:   $u -> $got"
    fi
}

run hdtrading pass      # config present
run odoo18    pass      # unit present
run games     refuse    # neither

[ "$fails" -eq 0 ] && echo "PASS" || exit 1
