#!/usr/bin/make

#-----------------------------------------------------------------------------

#DIALYZER_PLT = ~/.dialyzer_plt
DIALYZER_OPTS = --no_check_plt $(foreach D,$(DIALYZER_PLT),--plt $D)

#-----------------------------------------------------------------------------

.PHONY: all doc edoc compile build clean dialyzer

all: compile doc

build: compile
edoc: doc

compile clean doc:
	rebar $@

YECC_ERL_FILES = $(subst .yrl,.erl,$(subst .xrl,.erl,$(wildcard src/*.[xy]rl)))
ERL_SOURCE_FILES = $(filter-out $(YECC_ERL_FILES),$(wildcard src/*.erl))
dialyzer:
	@echo "dialyzer $(strip $(DIALYZER_OPTS)) --src src/*.erl"
	@dialyzer $(strip $(DIALYZER_OPTS)) --src $(ERL_SOURCE_FILES)

#-----------------------------------------------------------------------------
# vim:ft=make
