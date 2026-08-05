# Install the toolkit as a single `abo` command.
#
#   sudo make install                 -> /usr/local/bin/abo
#   sudo make install PREFIX=/usr     -> /usr/bin/abo
#   sudo make uninstall
#   make check                        -> shellcheck + bash -n (the only checks here)
#
# The subcommand scripts go in <prefix>/lib/abo rather than on PATH: they are
# named odoo_*.sh and would collide with nothing, but they are implementation,
# and keeping them together is what lets each one find its siblings.
#
# DESTDIR is honoured for packaging.

PREFIX  ?= /usr/local
BINDIR   = $(DESTDIR)$(PREFIX)/bin
LIBDIR   = $(DESTDIR)$(PREFIX)/lib/abo

SCRIPTS = odoo_install.sh odoo_nginx.sh odoo_backup.sh odoo_update.sh odoo_remove.sh \
          odoo_ssl.sh odoo_status.sh

# Removed in 2.3.0, when the three flat commands became `abo` subcommands.
LEGACY = odoo-install odoo-nginx odoo-backup

.PHONY: all install uninstall check

all:
	@echo "Nothing to build — these are shell scripts."
	@echo "Run 'sudo make install' to put 'abo' on PATH."

install:
	install -d $(BINDIR) $(LIBDIR)
	install -m 755 abo $(BINDIR)/abo
	install -m 755 $(SCRIPTS) $(LIBDIR)/
	install -m 644 requirements.txt $(LIBDIR)/requirements.txt
	@rm -f $(addprefix $(BINDIR)/,$(LEGACY))
	@rm -rf $(DESTDIR)$(PREFIX)/share/odoo-install
	@echo ""
	@echo "Installed: $(BINDIR)/abo"
	@echo "Scripts:   $(LIBDIR)/"
	@echo ""
	@echo "  sudo abo install      provision an instance"
	@echo "  abo help              all commands"

uninstall:
	rm -f $(BINDIR)/abo
	rm -f $(addprefix $(BINDIR)/,$(LEGACY))
	rm -rf $(LIBDIR)

check:
	shellcheck abo $(SCRIPTS)
	@for f in abo $(SCRIPTS); do bash -n $$f || exit 1; done
	@echo "OK"
