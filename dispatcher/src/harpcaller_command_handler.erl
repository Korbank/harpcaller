%%%---------------------------------------------------------------------------
%%% @doc
%%%   Administrative command handler for Indira.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_command_handler).

-behaviour(gen_indira_command).

%% gen_indira_command callbacks
-export([handle_command/2]).

%% interface for `harpcaller_cli_handler'
-export([format_request/1, parse_reply/2, hardcoded_reply/1]).

%%%---------------------------------------------------------------------------
%%% gen_indira_command callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% daemon control

%% @private
%% @doc Handle administrative commands sent to the daemon.

handle_command([{<<"command">>, <<"status">>}, {<<"wait">>, false}] = _Command,
               _Args) ->
  case indira:is_started(harpcaller) of
    true  -> [{result, running}];
    false -> [{result, stopped}]
  end;
handle_command([{<<"command">>, <<"status">>}, {<<"wait">>, true}] = _Command,
               _Args) ->
  case indira:wait_for_start(harpcaller_sup) of
    ok    -> [{result, running}];
    error -> [{result, stopped}]
  end;

handle_command([{<<"command">>, <<"stop">>}] = _Command, _Args) ->
  log_info(stop, "stopping HarpCaller daemon", []),
  init:stop(),
  [{result, ok}, {pid, list_to_binary(os:getpid())}];

handle_command([{<<"command">>, <<"reload_config">>}] = _Command, _Args) ->
  log_info(reload, "reloading configuration", []),
  try indira:reload() of
    ok ->
      [{result, ok}];
    {error, reload_not_set} ->
      [{result, error}, {message, <<"not configured from file">>}];
    {error, reload_in_progress} ->
      log_info(reload, "another reload in progress", []),
      [{result, error}, {message, <<"reload command already in progress">>}];
    {error, Message} when is_binary(Message) ->
      log_error(reload, "reload error", [{error, Message}]),
      [{result, error}, {message, Message}];
    {error, Errors} when is_list(Errors) ->
      log_error(reload, "reload errors", [{errors, Errors}]),
      [{result, error}, {errors, Errors}]
  catch
    Type:Error ->
      % XXX: this crash should never happen and is a programming error
      log_error(reload, "reload crash", [
        {crash, Type}, {error, {term, Error}},
        {stack_trace, indira:format_stacktrace(erlang:get_stacktrace())}
      ]),
      [{result, error},
        {message, <<"reload function crashed, check logs for details">>}]
  end;

%%----------------------------------------------------------
%% Log handling/rotation

handle_command([{<<"command">>, <<"prune_jobs">>},
                {<<"max_age">>, Age}] = _Command, _Args) ->
  log_info(prune_jobs, "pruning old jobs", [{max_age, Age}]),
  harp_sdb:remove_older(Age), % TODO: return removed count and error count
  [{result, ok}];

handle_command([{<<"command">>, <<"reopen_logs">>}] = _Command, _Args) ->
  log_info(reopen_logs, "reopening log files", []),
  case application:get_env(harpcaller, error_logger_file) of
    {ok, Path} ->
      case indira_disk_h:reopen(error_logger, Path) of
        ok ->
          [{result, ok}];
        {error, Reason} ->
          Message = iolist_to_binary([
            "can't open ", Path, ": ", indira_disk_h:format_error(Reason)
          ]),
          log_error(reopen_logs, "error_logger reopen error",
                    [{error, Message}]),
          [{result, error}, {message, Message}]
      end;
    undefined ->
      indira_disk_h:remove(error_logger),
      [{result, ok}]
  end;

%%----------------------------------------------------------
%% RPC job control

handle_command([{<<"command">>, <<"list_jobs">>},
                {<<"list_all">>, AllJobs}] = _Command, _Args) ->
  case AllJobs of
    true ->
      Jobs = list_recorded_jobs_info(),
      [{result, ok}, {jobs, Jobs}];
    false ->
      Jobs = list_running_jobs_info(),
      [{result, ok}, {jobs, Jobs}];
    _ ->
      [{result, error}, {message, <<"unrecognized command">>}]
  end;

handle_command([{<<"command">>, <<"cancel_job">>},
                {<<"job">>, JobID}] = _Command, _Args) ->
  log_info(cancel_job, "cancelling a job", [{job, JobID}]),
  case harpcaller_caller:cancel(binary_to_list(JobID)) of
    ok -> [{result, ok}];
    undefined -> [{result, no_such_job}]
  end;

handle_command([{<<"command">>, <<"job_info">>},
                {<<"job">>, JobID}] = _Command, _Args) ->
  case job_info(binary_to_list(JobID)) of
    JobInfo when is_list(JobInfo) ->
      [{result, ok}, {info, JobInfo}];
    undefined ->
      [{result, no_such_job}]
  end;

%%----------------------------------------------------------
%% hosts registry control

handle_command([{<<"command">>, <<"list_hosts">>}] = _Command, _Args) ->
  Hosts = [format_host_entry(H) || H <- harpcaller_hostdb:list()],
  [{result, ok}, {hosts, Hosts}];

handle_command([{<<"command">>, <<"refresh_hosts">>}] = _Command, _Args) ->
  log_info(refresh_hosts, "refreshing hosts", []),
  harpcaller_hostdb:refresh(),
  [{result, ok}];

%%----------------------------------------------------------
%% queues control

handle_command([{<<"command">>, <<"list_queues">>}] = _Command, _Args) ->
  {ok, Queues} = harpcaller_call_queue:list(),
  [{result, ok}, {queues, Queues}];

handle_command([{<<"command">>, <<"list_queue">>},
                {<<"queue">>, Queue}] = _Command, _Args) ->
  Jobs = list_queue(Queue),
  [{result, ok}, {jobs, Jobs}];

handle_command([{<<"command">>, <<"cancel_queue">>},
                {<<"queue">>, Queue}] = _Command, _Args) ->
  log_info(cancel_queue, "cancelling all jobs in a queue", [{queue, Queue}]),
  harpcaller_call_queue:cancel(Queue),
  [{result, ok}];

%%----------------------------------------------------------
%% Erlang networking control

handle_command([{<<"command">>, <<"dist_start">>}] = _Command, _Args) ->
  log_info(dist_start, "starting Erlang networking", []),
  case indira:distributed_start() of
    ok ->
      [{result, ok}];
    {error, Reason} ->
      log_error(dist_start, "can't setup Erlang networking",
                [{error, {term, Reason}}]),
      [{result, error}, {message, <<"Erlang networking error">>}]
  end;

handle_command([{<<"command">>, <<"dist_stop">>}] = _Command, _Args) ->
  log_info(dist_stop, "stopping Erlang networking", []),
  case indira:distributed_stop() of
    ok ->
      [{result, ok}];
    {error, Reason} ->
      log_error(dist_stop, "can't shutdown Erlang networking",
                [{error, {term, Reason}}]),
      [{result, error}, {message, <<"Erlang networking error">>}]
  end;

%%----------------------------------------------------------

handle_command(_Command, _Args) ->
  [{result, error}, {message, <<"unrecognized command">>}].

%%%---------------------------------------------------------------------------
%%% interface for `harpcaller_cli_handler'
%%%---------------------------------------------------------------------------

%% @doc Encode administrative command as a serializable structure.

-spec format_request(gen_indira_cli:command()) ->
  gen_indira_cli:request().

format_request(status        = Command) -> [{command, Command}, {wait, false}];
format_request(status_wait   =_Command) -> [{command, status}, {wait, true}];
format_request(stop          = Command) -> [{command, Command}];
format_request(reload_config = Command) -> [{command, Command}];
format_request({prune_jobs, Days} = _Command) -> [{command, prune_jobs}, {max_age, Days * 24 * 3600}];
format_request(reopen_logs   = Command) -> [{command, Command}];
format_request(dist_start    = Command) -> [{command, Command}];
format_request(dist_stop     = Command) -> [{command, Command}];

format_request({list_jobs, AllJobs}) ->
  [{command, list_jobs}, {list_all, AllJobs}];
format_request({cancel_job, JobID}) when is_list(JobID) ->
  format_request({cancel_job, list_to_binary(JobID)});
format_request({cancel_job, JobID}) when is_binary(JobID) ->
  [{command, cancel_job}, {job, JobID}];
format_request({job_info, JobID}) when is_list(JobID) ->
  format_request({job_info, list_to_binary(JobID)});
format_request({job_info, JobID}) when is_binary(JobID) ->
  [{command, job_info}, {job, JobID}];

format_request(list_hosts) ->
  [{command, list_hosts}];
format_request(refresh_hosts) ->
  [{command, refresh_hosts}];

format_request(list_queues) ->
  [{command, list_queues}];
format_request({list_queue, Queue}) ->
  [{command, list_queue}, {queue, Queue}];
format_request({cancel_queue, Queue}) ->
  [{command, cancel_queue}, {queue, Queue}].

parse_reply([{<<"result">>, <<"ok">>}] = _Reply, _Request) ->
  ok;
parse_reply([{<<"message">>, Reason}, {<<"result">>, <<"error">>}] = _Reply,
            _Request) when is_binary(Reason) ->
  {error, Reason};
parse_reply([{<<"errors">>, [{_,_}|_] = Errors},
              {<<"result">>, <<"error">>}] = _Reply,
            reload_config = _Request) ->
  {error, Errors};

parse_reply([{<<"result">>, <<"running">>}] = _Reply, status = _Request) ->
  running;
parse_reply([{<<"result">>, <<"stopped">>}] = _Reply, status = _Request) ->
  stopped;

parse_reply([{<<"pid">>, Pid}, {<<"result">>, <<"ok">>}] = _Reply,
            stop = _Request) when is_binary(Pid) ->
  {ok, binary_to_list(Pid)};

parse_reply([{<<"info">>, JobInfo}, {<<"result">>, <<"ok">>}] = _Reply,
            {job_info, _} = _Request) ->
  {ok, JobInfo};
parse_reply([{<<"result">>, <<"no_such_job">>}] = _Reply,
            {job_info, _} = _Request) ->
  {error, <<"no such job">>};

parse_reply([{<<"jobs">>, Jobs}, {<<"result">>, <<"ok">>}] = _Reply,
            list_jobs = _Request) when is_list(Jobs) ->
  {ok, Jobs};

parse_reply([{<<"result">>, <<"no_such_job">>}] = _Reply,
            {cancel_job, _} = _Request) ->
  {error, <<"no such job">>};

parse_reply([{<<"hosts">>, Hosts}, {<<"result">>, <<"ok">>}] = _Reply,
            list_hosts = _Request) when is_list(Hosts) ->
  {ok, Hosts};

parse_reply([{<<"queues">>, Queues}, {<<"result">>, <<"ok">>}] = _Reply,
            list_queues = _Request) when is_list(Queues) ->
  {ok, Queues};

parse_reply([{<<"jobs">>, Jobs}, {<<"result">>, <<"ok">>}] = _Reply,
            {list_queue, _} = _Request) when is_list(Jobs) ->
  {ok, Jobs};

parse_reply(_Reply, _Request) ->
  {error, <<"unrecognized reply from daemon">>}.

hardcoded_reply(generic_ok = _Reply) ->
  [{<<"result">>, <<"ok">>}];
hardcoded_reply(daemon_stopped = _Reply) ->
  [{<<"result">>, <<"stopped">>}].

%%%---------------------------------------------------------------------------
%%% helper functions
%%%---------------------------------------------------------------------------

list_running_jobs_info() ->
  _Result = [
    add_job_queue(pid_job_info(Pid)) ||
    {_,Pid,_,_} <- supervisor:which_children(harpcaller_caller_sup)
  ].

pid_job_info(Pid) ->
  % TODO: catch errors from `harpcaller_caller:job_id()' when task terminated
  %   between listing processes and checking out its info
  {ok, JobID} = harpcaller_caller:job_id(Pid),
  job_info(JobID).

list_recorded_jobs_info() ->
  _Result = [add_job_queue(job_info(JobID)) || JobID <- harp_sdb:list()].

job_info(JobID) ->
  case harpcaller_caller:get_call_info(JobID) of
    {ok, {{ProcName, ProcArgs} = _ProcInfo, Host,
          {SubmitTime, StartTime, EndTime} = _TimeInfo, _CallInfo}} ->
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
      ];
    undefined ->
      undefined
    % XXX: let it die on other errors
  end.

add_job_queue(JobInfoRecord) ->
  JobID = binary_to_list(proplists:get_value(<<"job">>, JobInfoRecord)),
  case harpcaller_caller:get_call_queue(JobID) of
    {ok, QueueName} -> [{<<"queue">>, QueueName} | JobInfoRecord];
    undefined -> [{<<"queue">>, null} | JobInfoRecord]
  end.

format_host_entry({Hostname, Address, Port}) ->
  _Entry = [
    {<<"hostname">>, Hostname}, % binary
    {<<"address">>, format_address(Address)}, % list
    {<<"port">>, Port} % integer
  ].

list_queue(QueueName) ->
  {Running, Queued} = harpcaller_call_queue:list_processes(QueueName),
  _Result = [
    [{running, true} | pid_job_info(P)] || P <- Running
  ] ++ [
    [{running, false} | pid_job_info(P)] || P <- Queued
  ].

undef_null(undefined = _Value) -> null;
undef_null(Value) -> Value.

format_address({A,B,C,D} = _Address) ->
  % TODO: IPv6
  iolist_to_binary(io_lib:format("~B.~B.~B.~B", [A,B,C,D]));
format_address(Address) when is_list(Address) ->
  list_to_binary(Address).

%%%---------------------------------------------------------------------------
%%% operations logging
%%%---------------------------------------------------------------------------

-spec log_info(atom(), harpcaller_log:event_message(),
               harpcaller_log:event_info()) ->
  ok.

log_info(Command, Message, Context) ->
  harpcaller_log:info(command, Message, Context ++ [{command, {term, Command}}]).

-spec log_error(atom(), harpcaller_log:event_message(),
                harpcaller_log:event_info()) ->
  ok.

log_error(Command, Message, Context) ->
  harpcaller_log:warn(command, Message, Context ++ [{command, {term, Command}}]).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
