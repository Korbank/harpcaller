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

%%----------------------------------------------------------
%% daemon control

handle_command([{<<"command">>, <<"stop">>}] = _Command, _Args) ->
  init:stop(),
  [{result, ok}, {pid, list_to_binary(os:getpid())}];

handle_command([{<<"command">>, <<"wait_for_start">>}] = _Command, _Args) ->
  wait_for_start(),
  [{result, ok}];

handle_command([{<<"command">>, <<"reload_config">>}] = _Command, _Args) ->
  [{error, <<"command not implemented yet">>}];

%%----------------------------------------------------------
%% RPC job control

handle_command([{<<"command">>, <<"list_jobs">>}] = _Command, _Args) ->
  Jobs = list_jobs_info(),
  [{result, ok}, {jobs, Jobs}];

handle_command([{<<"command">>, <<"cancel_job">>},
                {<<"job">>, JobID}] = _Command, _Args) ->
  case korrpcdid_caller:cancel(binary_to_list(JobID)) of
    ok -> [{result, ok}];
    undefined -> [{result, no_such_job}]
  end;

%%----------------------------------------------------------
%% hosts registry control

handle_command([{<<"command">>, <<"list_hosts">>}] = _Command, _Args) ->
  Hosts = list_hosts(),
  [{result, ok}, {hosts, Hosts}];

handle_command([{<<"command">>, <<"refresh_hosts">>}] = _Command, _Args) ->
  korrpcdid_hostdb:refresh(),
  [{result, ok}];

%%----------------------------------------------------------
%% queues control

handle_command([{<<"command">>, <<"list_queues">>}] = _Command, _Args) ->
  % [{result, ok}, {queues, [...]}]
  [{error, <<"command not implemented yet">>}];

handle_command([{<<"command">>, <<"list_queue">>},
                {<<"queue">>, _Queue}] = _Command, _Args) ->
  % Jobs = list_jobs_info(Queue),
  % [{result, ok}, {jobs, Jobs}]
  [{error, <<"command not implemented yet">>}];

handle_command([{<<"command">>, <<"cancel_queue">>},
                {<<"queue">>, Queue}] = _Command, _Args) ->
  korrpcdid_call_queue:cancel(Queue),
  [{result, ok}];

%%----------------------------------------------------------
%% Erlang networking control

handle_command([{<<"command">>, <<"dist_start">>}] = _Command, _Args) ->
  % TODO: handle errors
  ok = indira:distributed_start(),
  [{result, ok}];

handle_command([{<<"command">>, <<"dist_stop">>}] = _Command, _Args) ->
  % TODO: handle errors
  ok = indira:distributed_stop(),
  [{result, ok}];

handle_command(Command, _Args) ->
  io:fwrite("got command ~p~n", [Command]),
  [{error, <<"unsupported command">>}].

%%----------------------------------------------------------

wait_for_start() ->
  case whereis(korrpcdid_sup) of
    Pid when is_pid(Pid) -> ok;
    undefined -> timer:sleep(100), wait_for_start()
  end.

list_jobs_info() ->
  _Result = [
    job_info(Pid) ||
    {_,Pid,_,_} <- supervisor:which_children(korrpcdid_caller_sup)
  ].

job_info(Pid) ->
  % TODO: catch errors from `korrpcdid_caller:job_id()' when task terminated
  %   between listing processes and checking out their info
  JobID = korrpcdid_caller:job_id(Pid),
  {ok, {ProcInfo, Host, TimeInfo}} = korrpcdid_caller:get_call_info(JobID),
  {ProcName, ProcArgs} = ProcInfo,
  {SubmitTime, StartTime, EndTime} = TimeInfo,
  _JobInfo = [
    {<<"job">>, list_to_binary(JobID)},
    {<<"call">>, [
      {<<"procedure">>, ProcName},
      {<<"arguments">>, ProcArgs},
      {<<"host">>, Host}
    ]},
    {<<"time">>, [
      {<<"submit">>, undef_null(SubmitTime)}, % non-null, but consistency
      {<<"start">>,  undef_null(StartTime)},
      {<<"end">>,    undef_null(EndTime)}
    ]}
  ].

list_hosts() ->
  [format_host_entry(H) || H <- korrpcdid_hostdb:list()].

format_host_entry({Hostname, Address, Port}) ->
  _Entry = [
    {<<"hostname">>, Hostname}, % binary
    {<<"address">>, format_address(Address)}, % list
    {<<"port">>, Port} % integer
  ].

%%----------------------------------------------------------

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

command_list_queue(Queue) ->
  {ok, QueueStruct} = indira_json:decode(Queue),
  [{command, list_queue}, {queue, QueueStruct}].

reply_list_queue([{<<"jobs">>, Jobs}, {<<"result">>, <<"ok">>}] = _Reply) ->
  {ok, Jobs};
reply_list_queue(Reply) ->
  {error, invalid_reply(Reply)}.

command_cancel_queue(Queue) ->
  {ok, QueueStruct} = indira_json:decode(Queue),
  [{command, cancel_queue}, {queue, QueueStruct}].

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

undef_null(undefined = _Value) -> null;
undef_null(Value) -> Value.

format_address({A,B,C,D} = _Address) ->
  % TODO: IPv6
  iolist_to_binary(io_lib:format("~B.~B.~B.~B", [A,B,C,D]));
format_address(Address) when is_list(Address) ->
  list_to_binary(Address).

%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
