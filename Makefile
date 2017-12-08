#!/usr/bin/make -f

#-----------------------------------------------------------------------------

.PHONY: default help
default: help

.SILENT: help
help:
	echo "Available targets:"
	echo "  help"
	echo "  all"
	echo "  install DESTDIR=..."
	echo "  clean"
	echo "  doc"
	echo "  doc-clean"

#-----------------------------------------------------------------------------

.PHONY: all install clean
.PHONY: daemon dispatcher harp
.PHONY: daemon-install dispatcher-install harp-install
.PHONY: daemon-clean dispatcher-clean harp-clean

all: harp daemon dispatcher doc
install: harp-install daemon-install dispatcher-install doc-install
clean: harp-clean daemon-clean dispatcher-clean doc-clean

harp daemon dispatcher:
	$(MAKE) all -C $@

harp-install daemon-install dispatcher-install:
	$(MAKE) install -C $(patsubst %-install,%,$@)

harp-clean daemon-clean dispatcher-clean:
	$(MAKE) clean -C $(patsubst %-clean,%,$@)

#-----------------------------------------------------------------------------

.PHONY: doc html man doc-install doc-clean
doc: html man

html:
	$(MAKE) -C doc $@
	$(MAKE) -C dispatcher doc

man:
	$(MAKE) -C doc $@

doc-clean:
	$(MAKE) -C doc clean

doc-install:
	mkdir -p $(DESTDIR)/usr/share/doc/harpcaller
	mkdir -p $(DESTDIR)/usr/share/doc/harpcaller/html
	cp -R doc/html/* $(DESTDIR)/usr/share/doc/harpcaller/html
	install -D -m 644 doc/man/harp.3 $(DESTDIR)/usr/share/man/man3/harp.3
	install -D -m 644 doc/man/harpcaller.7 $(DESTDIR)/usr/share/man/man7/harpcaller.7
	install -D -m 644 doc/man/harpcallerd.8 $(DESTDIR)/usr/share/man/man8/harpcallerd.8
	install -D -m 644 doc/man/harpd.8 $(DESTDIR)/usr/share/man/man8/harpd.8
	$(MAKE) -C dispatcher install-doc DESTDIR=$(DESTDIR)

#-----------------------------------------------------------------------------
# vim:ft=make
