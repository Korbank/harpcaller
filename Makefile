#!/usr/bin/make -f

SPHINX_DOCTREE = documentation/doctrees
SPHINX_SOURCE = documentation
SPHINX_OUTPUT = documentation/html

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

harp: harp/version
daemon: daemon/version
dispatcher: dispatcher/version

harp daemon dispatcher:
	$(MAKE) all -C $@

harp-install daemon-install dispatcher-install:
	$(MAKE) install -C $(patsubst %-install,%,$@)

harp-clean daemon-clean dispatcher-clean:
	$(MAKE) clean -C $(patsubst %-clean,%,$@)

harp/version daemon/version dispatcher/version:
	git describe --long --dirty --match='v*' --abbrev=10 --tags > $@

#-----------------------------------------------------------------------------

.PHONY: doc html doc-install doc-clean
doc: html

html:
	sphinx-build -b html -d $(SPHINX_DOCTREE) $(SPHINX_SOURCE) $(SPHINX_OUTPUT)

doc-install:
	mkdir -p $(DESTDIR)/usr/share/doc/harpcaller/html
	cp -R $(SPHINX_OUTPUT)/* $(DESTDIR)/usr/share/doc/harpcaller/html

doc-clean:
	rm -rf $(SPHINX_DOCTREE) $(SPHINX_OUTPUT)

#-----------------------------------------------------------------------------
# vim:ft=make
