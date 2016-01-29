#!/usr/bin/make -f

SPHINX_DOCTREE = documentation/doctrees
SPHINX_SOURCE = documentation
SPHINX_OUTPUT = documentation/html

#-----------------------------------------------------------------------------

.PHONY: default all help
default: help

.SILENT: help
help:
	echo "Available targets:"
	echo "  help"
	echo "  doc"
	echo "  doc-clean"

#-----------------------------------------------------------------------------

.PHONY: doc html doc-clean
doc: html

html:
	sphinx-build -b html -d $(SPHINX_DOCTREE) $(SPHINX_SOURCE) $(SPHINX_OUTPUT)

doc-clean:
	rm -rf $(SPHINX_DOCTREE) $(SPHINX_OUTPUT)

#-----------------------------------------------------------------------------
# vim:ft=make
