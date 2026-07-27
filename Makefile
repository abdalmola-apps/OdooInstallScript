# Install the three scripts as system commands.
#
#   sudo make install                 -> /usr/local/bin/odoo-install, ...
#   sudo make install PREFIX=/usr     -> /usr/bin/odoo-install, ...
#   sudo make uninstall
#   make check                        -> shellcheck (the only checker here)
#
# DESTDIR is honoured for packaging.

PREFIX  ?= /usr/local
BINDIR   = $(DESTDIR)$(PREFIX)/bin
DATADIR  = $(DESTDIR)$(PREFIX)/share/odoo-install

SCRIPTS  = odoo_install.sh odoo_nginx.sh odoo_backup.sh
COMMANDS = odoo-install odoo-nginx odoo-backup

.PHONY: all install uninstall check

all:
	@echo "Nothing to build — these are shell scripts."
	@echo "Run 'sudo make install' to put them on PATH."

install:
	install -d $(BINDIR) $(DATADIR)
	install -m 755 odoo_install.sh $(BINDIR)/odoo-install
	install -m 755 odoo_nginx.sh   $(BINDIR)/odoo-nginx
	install -m 755 odoo_backup.sh  $(BINDIR)/odoo-backup
	install -m 644 requirements.txt $(DATADIR)/requirements.txt
	@echo ""
	@echo "Installed: $(COMMANDS) in $(DESTDIR)$(PREFIX)/bin"
	@echo "Start with: sudo odoo-install"

uninstall:
	rm -f $(addprefix $(BINDIR)/,$(COMMANDS))
	rm -f $(DATADIR)/requirements.txt
	-rmdir $(DATADIR) 2>/dev/null || true

check:
	shellcheck $(SCRIPTS)
	@for f in $(SCRIPTS); do bash -n $$f || exit 1; done
	@echo "OK"
