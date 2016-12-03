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

ERL_APP_FILE = $(wildcard ebin/*.app)
ERL_APP_NAME = $(patsubst ebin/%.app,%,$(ERL_APP_FILE))
ERL_APP_VER = $(shell _install/app_version $(ERL_APP_FILE))
ERL_INSTALL_PATH = $(shell _install/lib_dir)
ESCRIPT_ARGS_FILE = /etc/harpcaller/erlang.args

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
install:
	mkdir -p $(DESTDIR)/usr/sbin
	mkdir -p $(DESTDIR)/etc/harpcaller
	mkdir -p $(DESTDIR)$(ERL_INSTALL_PATH)/$(ERL_APP_NAME)-$(ERL_APP_VER)/ebin
	install -m 644 ebin/*.app ebin/*.beam $(DESTDIR)$(ERL_INSTALL_PATH)/$(ERL_APP_NAME)-$(ERL_APP_VER)/ebin
	sed 's:^%%!.*:%%! -noinput -kernel error_logger silent -args_file $(ESCRIPT_ARGS_FILE):' bin/harpcallerd > $(DESTDIR)/usr/sbin/harpcallerd
	chmod 755 $(DESTDIR)/usr/sbin/harpcallerd
	install -m 644 examples/harpcaller.toml $(DESTDIR)/etc/harpcaller/harpcaller.toml.example
	touch $(DESTDIR)$(ESCRIPT_ARGS_FILE)
	mkdir -p $(DESTDIR)/usr/share/doc/harpcaller/internals
	cp -R doc $(DESTDIR)/usr/share/doc/harpcaller/internals/html

#-----------------------------------------------------------------------------
# vim:ft=make
