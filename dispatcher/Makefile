#!/usr/bin/make

#-----------------------------------------------------------------------------

#DIALYZER_PLT = ~/.dialyzer_plt
DIALYZER_OPTS = --no_check_plt $(foreach D,$(DIALYZER_PLT),--plt $D)

#-----------------------------------------------------------------------------

.PHONY: all doc edoc compile build dialyzer

all: compile doc

doc edoc:
	rebar doc

compile build:
	rebar compile

dialyzer:
	dialyzer $(strip $(DIALYZER_OPTS)) --src src

#-----------------------------------------------------------------------------
# vim:ft=make
