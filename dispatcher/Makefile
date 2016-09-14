#!/usr/bin/make

#-----------------------------------------------------------------------------

ifeq ($(wildcard .*.plt),)
#DIALYZER_PLT = ~/.dialyzer_plt
else
DIALYZER_PLT = ~/.dialyzer_plt $(wildcard .*.plt)
endif
DIALYZER_OPTS = --no_check_plt $(if $(DIALYZER_PLT),--plts $(DIALYZER_PLT))

DIAGRAMS = $(basename $(notdir $(wildcard diagrams/*.diag)))
DIAGRAMS_SVG = $(foreach D,$(DIAGRAMS),doc/images/$D.svg)

#-----------------------------------------------------------------------------

.PHONY: all doc edoc diagrams compile build clean dialyzer

all: compile doc

build: compile
edoc: doc
doc: diagrams

compile clean doc:
	rebar $@

diagrams: $(DIAGRAMS_SVG)

doc/images/%.svg: diagrams/%.diag
	blockdiag -o $@ -T svg $<

YECC_ERL_FILES = $(subst .yrl,.erl,$(subst .xrl,.erl,$(wildcard src/*.[xy]rl)))
ERL_SOURCE_FILES = $(filter-out $(YECC_ERL_FILES),$(wildcard src/*.erl))
dialyzer:
	@echo "dialyzer $(strip $(DIALYZER_OPTS)) --src src/*.erl"
	@dialyzer $(strip $(DIALYZER_OPTS)) --src $(ERL_SOURCE_FILES)

#-----------------------------------------------------------------------------

.PHONY: install
install: ERL_APP_NAME = $(patsubst ebin/%.app,%,$(wildcard ebin/*.app))
install: ERL_APP_VERSION = $(subst v,,$(word 1,$(subst -, ,$(shell cat version))))
install: ERL_LIBS_DIR = $(shell erl -noshell -eval 'io:put_chars([code:lib_dir(), "\n"]), halt()')
install: ERL_APP_DIR = $(ERL_LIBS_DIR)/$(ERL_APP_NAME)-$(ERL_APP_VERSION)
install: ESCRIPT_ARGS_FILE = /etc/harpcaller/erlang.args
install:
	mkdir -p $(DESTDIR)$(ERL_APP_DIR)/ebin
	cp ebin/*.app ebin/*.beam $(DESTDIR)$(ERL_APP_DIR)/ebin
	mkdir -p $(DESTDIR)/usr/sbin
	mkdir -p $(DESTDIR)/etc/harpcaller
	sed 's:^%%!.*:%%! -noinput -kernel error_logger silent -args_file $(ESCRIPT_ARGS_FILE):' bin/harpcallerd > $(DESTDIR)/usr/sbin/harpcallerd
	chmod 755 $(DESTDIR)/usr/sbin/harpcallerd
	install -m 644 examples/harpcaller.toml $(DESTDIR)/etc/harpcaller/harpcaller.toml.example
	touch $(DESTDIR)$(ESCRIPT_ARGS_FILE)
	mkdir -p $(DESTDIR)/usr/share/doc/harpcaller/internals
	cp -R doc $(DESTDIR)/usr/share/doc/harpcaller/internals/html

#-----------------------------------------------------------------------------
# vim:ft=make
