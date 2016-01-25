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
-export([reply_wait_for_start/1, reply_stop/1, reply_reload_config/1]).
%% RPC job control
-export([command_list_jobs/0, command_cancel_job/1]).
-export([reply_list_jobs/1, reply_cancel_job/1]).
%% hosts registry control
-export([command_list_hosts/0, command_refresh_hosts/0]).
-export([reply_list_hosts/1, reply_refresh_hosts/1]).
%% queues control
-export([command_list_queues/0, command_list_queue/1, command_cancel_queue/1]).
-export([reply_list_queues/1, reply_list_queue/1, reply_cancel_queue/1]).
%% Erlang networking control
-export([command_dist_start/0, command_dist_stop/0]).
-export([reply_dist_start/1, reply_dist_stop/1]).

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

reply_wait_for_start([{<<"result">>, <<"ok">>}] = _Reply) -> ok;
reply_wait_for_start(Reply) -> {error, invalid_reply(Reply)}.

command_stop() ->
  [{command, stop}].

reply_stop([{<<"pid">>, Pid}, {<<"result">>, <<"ok">>}] = _Reply)
when is_binary(Pid) ->
  {ok, binary_to_list(Pid)};
reply_stop(Reply) ->
  {error, invalid_reply(Reply)}.

command_reload_config() ->
  [{command, reload_config}].

reply_reload_config([{<<"result">>, <<"ok">>}] = _Reply) -> ok;
reply_reload_config(Reply) -> {error, invalid_reply(Reply)}.

%% }}}
%%----------------------------------------------------------
%% RPC job control {{{

command_list_jobs() ->
  [{command, list_jobs}].

reply_list_jobs([{<<"jobs">>, Jobs}, {<<"result">>, <<"ok">>}] = _Reply) ->
  {ok, Jobs};
reply_list_jobs(Reply) ->
  {error, invalid_reply(Reply)}.

command_cancel_job(JobID) when is_list(JobID) ->
  command_cancel_job(list_to_binary(JobID));
command_cancel_job(JobID) when is_binary(JobID) ->
  [{command, cancel_job}, {job, JobID}].

reply_cancel_job([{<<"result">>, <<"ok">>}] = _Reply) -> ok;
reply_cancel_job([{<<"result">>, <<"no_such_job">>}] = _Reply) -> {error, "no such job"};
reply_cancel_job(Reply) -> {error, invalid_reply(Reply)}.

%% }}}
%%----------------------------------------------------------
%% hosts registry control {{{

command_list_hosts() ->
  [{command, list_hosts}].

reply_list_hosts([{<<"hosts">>, Hosts}, {<<"result">>, <<"ok">>}] = _Reply) ->
  {ok, Hosts};
reply_list_hosts(Reply) ->
  {error, invalid_reply(Reply)}.

command_refresh_hosts() ->
  [{command, refresh_hosts}].

reply_refresh_hosts([{<<"result">>, <<"ok">>}] = _Reply) -> ok;
reply_refresh_hosts(Reply) -> {error, invalid_reply(Reply)}.

%% }}}
%%----------------------------------------------------------
%% queues control {{{

command_list_queues() ->
  [{command, list_queues}].

reply_list_queues([{<<"queues">>, Queues}, {<<"result">>, <<"ok">>}] = _Reply) ->
  {ok, Queues};
reply_list_queues(Reply) ->
  {error, invalid_reply(Reply)}.

command_list_queue(Queue) when is_list(Queue) ->
  command_list_queue(list_to_binary(Queue));
command_list_queue(Queue) when is_binary(Queue) ->
  [{command, list_queue}, {queue, Queue}].

reply_list_queue([{<<"jobs">>, Jobs}, {<<"result">>, <<"ok">>}] = _Reply) ->
  {ok, Jobs};
reply_list_queue([{<<"result">>, <<"no_such_queue">>}] = _Reply) ->
  {error, "no such queue"};
reply_list_queue(Reply) ->
  {error, invalid_reply(Reply)}.

command_cancel_queue(Queue) when is_list(Queue) ->
  command_cancel_queue(list_to_binary(Queue));
command_cancel_queue(Queue) ->
  [{command, cancel_queue}, {queue, Queue}].

reply_cancel_queue([{<<"result">>, <<"ok">>}] = _Reply) -> ok;
reply_cancel_queue(Reply) -> {error, invalid_reply(Reply)}.

%% }}}
%%----------------------------------------------------------
%% Erlang networking control {{{

command_dist_start() ->
  [{command, dist_start}].

reply_dist_start([{<<"result">>, <<"ok">>}] = _Reply) ->
  ok;
reply_dist_start([{<<"reason">>, Reason},
                  {<<"result">>, <<"error">>}] = _Reply)
when is_binary(Reason) ->
  {error, Reason};
reply_dist_start(Reply) ->
  {error, invalid_reply(Reply)}.

command_dist_stop() ->
  [{command, dist_stop}].

reply_dist_stop([{<<"result">>, <<"ok">>}] = _Reply) ->
  ok;
reply_dist_stop([{<<"reason">>, Reason},
                  {<<"result">>, <<"error">>}] = _Reply)
when is_binary(Reason) ->
  {error, Reason};
reply_dist_stop(Reply) ->
  {error, invalid_reply(Reply)}.

%% }}}
%%----------------------------------------------------------

invalid_reply(Reply) ->
  {ok, ReplyJSON} = indira_json:encode(Reply),
  ["invalid reply line: ", ReplyJSON].

%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
