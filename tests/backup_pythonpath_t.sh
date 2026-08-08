#!/bin/bash
# Check that odoo_backup.sh names the Odoo source root for click-odoo.
#
# Odoo is never pip-installed into the instance venv — the systemd unit only
# resolves `import odoo` through WorkingDirectory. Backups run from cron's cwd,
# so click_odoo's `import odoo` needs PYTHONPATH or it dies before it starts.
set -euo pipefail

SRC="${1:-$(dirname "$0")/../odoo_backup.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ok()   { echo "ok:   $*"; }

# The invocation must carry PYTHONPATH. Matched on the two-line command as it
# is written, so dropping the env prefix in a refactor fails here.
# shellcheck disable=SC2016  # a pattern matched against the script's text
PAT='sudo -u "\$OE_USER" -H env PYTHONPATH="\$OE_SRC[^"]*"\s*\\\n\s*"\$BACKUPDB"'
if grep -Pzoq "$PAT" "$SRC"; then
    ok "backupdb is invoked with PYTHONPATH=\$OE_SRC"
else
    fail "the click-odoo-backupdb call no longer sets PYTHONPATH"
fi

# An existing PYTHONPATH must be appended, not replaced — same expansion the
# script uses.
PYTHONPATH=/pre/existing
JOINED="/src${PYTHONPATH:+:$PYTHONPATH}"
unset PYTHONPATH
if [ "$JOINED" = "/src:/pre/existing" ]; then
    ok "an inherited PYTHONPATH is appended"
else
    fail "the :+ expansion drops the inherited PYTHONPATH: $JOINED"
fi

# And the mechanism itself: a source tree at $OE_SRC makes `import odoo` work
# from an unrelated cwd, which is the whole point.
mkdir -p "$T/src/odoo" "$T/elsewhere"
: > "$T/src/odoo/__init__.py"

if (cd "$T/elsewhere" && PYTHONPATH="$T/src" python3 -c 'import odoo' 2>/dev/null); then
    ok "PYTHONPATH=\$OE_SRC resolves 'import odoo' from another directory"
else
    fail "PYTHONPATH did not make the source tree importable"
fi

# One invocation, output captured — a pipeline here would trip pipefail on
# python's own non-zero exit and mask the assertion.
if out="$(cd "$T/elsewhere" && env -u PYTHONPATH python3 -c 'import odoo' 2>&1)"; then
    echo "skip: 'odoo' is importable system-wide here, negative case not meaningful"
elif grep -q "No module named 'odoo'" <<<"$out"; then
    ok "without it, the reported ModuleNotFoundError is reproduced"
else
    fail "expected ModuleNotFoundError without PYTHONPATH, got: $out"
fi

[ "$fails" -eq 0 ] && echo "PASS" || exit 1
