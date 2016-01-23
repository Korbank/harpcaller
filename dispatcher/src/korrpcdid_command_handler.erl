%%%---------------------------------------------------------------------------
%%% @doc
%%%   Administrative command handler for Indira.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_command_handler).

-behaviour(gen_indira_command).

%% gen_indira_command callbacks
-export([handle_command/2]).
%% daemon control
-export([command_wait_for_start/0, command_stop/0, command_reload_config/0]).
%% RPC job control
-export([command_list_jobs/0, command_cancel_job/1]).
%% hosts registry control
-export([command_list_hosts/0, command_refresh_hosts/0]).
%% queues control
-export([command_list_queues/0, command_list_queue/1, command_cancel_queue/1]).
%% Erlang networking control
-export([command_dist_start/0, command_dist_stop/0]).

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

%%----------------------------------------------------------
%% daemon control {{{

command_wait_for_start() ->
  [{command, wait_for_start}].

command_stop() ->
  [{command, stop}].

command_reload_config() ->
  [{command, reload_config}].

%% }}}
%%----------------------------------------------------------
%% RPC job control {{{

command_list_jobs() ->
  [{command, list_jobs}].

command_cancel_job(JobID) when is_list(JobID) ->
  command_cancel_job(list_to_binary(JobID));
command_cancel_job(JobID) when is_binary(JobID) ->
  [{command, list_jobs}, {job, JobID}].

%% }}}
%%----------------------------------------------------------
%% hosts registry control {{{

command_list_hosts() ->
  [{command, list_hosts}].

command_refresh_hosts() ->
  [{command, refresh_hosts}].

%% }}}
%%----------------------------------------------------------
%% queues control {{{

command_list_queues() ->
  [{command, list_queues}].

command_list_queue(Queue) when is_list(Queue) ->
  command_list_queue(list_to_binary(Queue));
command_list_queue(Queue) when is_binary(Queue) ->
  [{command, list_queue}, {queue, Queue}].

command_cancel_queue(Queue) when is_list(Queue) ->
  command_cancel_queue(list_to_binary(Queue));
command_cancel_queue(Queue) ->
  [{command, cancel_queue}, {queue, Queue}].

%% }}}
%%----------------------------------------------------------
%% Erlang networking control {{{

command_dist_start() ->
  [{command, dist_start}].

command_dist_stop() ->
  [{command, dist_stop}].

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
