%%%---------------------------------------------------------------------------
%%% @doc
%%%   Administrative command handler for Indira.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_command_handler).

-behaviour(gen_indira_command).

-export([handle_command/2]).

%%%---------------------------------------------------------------------------
%%% gen_indira_command callbacks
%%%---------------------------------------------------------------------------

handle_command([{<<"command">>, <<"stop">>}] = _Command, _Args) ->
  init:stop(),
  [{result, ok}, {pid, list_to_binary(os:getpid())}];

handle_command(Command, _Args) ->
  io:fwrite("got command ~p~n", [Command]),
  [{error, <<"unsupported command">>}].

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
