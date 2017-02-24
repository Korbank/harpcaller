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

html man:
	$(MAKE) -C documentation $@

doc-clean:
	$(MAKE) -C documentation clean

doc-install:
	mkdir -p $(DESTDIR)/usr/share/doc/harpcaller
	mkdir -p $(DESTDIR)/usr/share/doc/harpcaller/html
	cp -R documentation/html/* $(DESTDIR)/usr/share/doc/harpcaller/html

#-----------------------------------------------------------------------------
# vim:ft=make
