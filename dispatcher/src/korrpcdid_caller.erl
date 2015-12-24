%%%----------------------------------------------------------------------------
%%% @doc
%%%   Remote procedure calling process.
%%%   Process running this module calls remote procedure, receives whatever it
%%%   returns (both end result and streamed response), and records it in
%%%   {@link korrpc_sdb}.
%%% @end
%%%----------------------------------------------------------------------------

-module(korrpcdid_caller).

-behaviour(gen_server).

%% public interface
-export([call/3, call/4, locate/1]).
-export([cancel/1, get_result/1, follow_stream/1]).

%% supervision tree API
-export([start/4, start_link/4]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

%% I should probably keep `max_exec_time' and `timeout' as microseconds to
%% avoid multiplication and division, but `timeout()' type is usually
%% milliseconds (e.g. in `receive .. end'), so let's leave it this way
-record(state, {
  job_id       :: korrpcdid:job_id(),
  stream_table :: korrpc_sdb:handle(),
  call         :: korrpc:handle(),
  followers    :: ets:tab(),
  count = 0    :: non_neg_integer(),
  start_time   :: erlang:timestamp(),
  last_read    :: erlang:timestamp(),
  max_exec_time :: timeout(), % ms
  timeout      :: timeout()   % ms
}).

-include("korrpcdid_caller.hrl").

-define(RPC_READ_INTERVAL, 100).

-type call_option() ::
    {port, inet:port_number()}
  %| {credentials, term()}
  | {timeout, timeout()}
  | {max_exec_time, timeout()}.

% }}}
%%%---------------------------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Spawn a (supervised) caller process to call remote procedure.

-spec call(korrpc:procedure(), [korrpc:argument()],
           inet:hostname() | inet:ip_address() | binary()) ->
  {ok, pid(), korrpcdid:job_id()} | {error, term()}.

call(Procedure, Args, Host) ->
  call(Procedure, Args, Host, [{port, 1638}]).

%% @doc Spawn a (supervised) caller process to call remote procedure.

-spec call(korrpc:procedure(), [korrpc:argument()],
           inet:hostname() | inet:ip_address() | binary(), [call_option()]) ->
  {ok, pid(), korrpcdid:job_id()} | {error, term()}.

call(Procedure, Args, Host, Options) when is_binary(Host) ->
  call(Procedure, Args, binary_to_list(Host), Options);
call(Procedure, Args, Host, Options) when is_list(Options) ->
  korrpcdid_caller_sup:spawn_caller(Procedure, Args, Host, Options).

%% @doc Locate the process that carries out specified job ID.

-spec locate(korrpcdid:job_id()) ->
  {ok, pid()} | none.

locate(JobID) when is_list(JobID) ->
  case ets:lookup(?ETS_REGISTRY_TABLE, JobID) of
    [{JobID, Pid}] -> {ok, Pid};
    [] -> none
  end.

%% @doc Send a request to caller process responsible for a job.

-spec request(korrpcdid:job_id(), term()) ->
  term() | undefined.

request(JobID, Request) when is_list(JobID) ->
  case ets:lookup(?ETS_REGISTRY_TABLE, JobID) of
    [{JobID, Pid}] ->
      try
        gen_server:call(Pid, Request)
      catch
        exit:{noproc,_} -> undefined
      end;
    [] -> undefined
  end.

%% @doc Cancel remote call job.

-spec cancel(korrpcdid:job_id()) ->
  ok | undefined.

cancel(JobID) ->
  request(JobID, cancel).

%% @doc Retrieve result of a job (non-blocking).

-spec get_result(korrpcdid:job_id()) ->
    {return, korrpc:result()}
  | still_running
  | cancelled
  | missing
  | {exception, korrpc:error_description()}
  | {error, korrpc:error_description() | term()}
  | undefined.

get_result(JobID) ->
  case request(JobID, get_sdb) of
    {ok, StreamTable} ->
      korrpc_sdb:result(StreamTable);
    undefined ->
      case korrpc_sdb:load(JobID) of
        {ok, DBH} ->
          Result = korrpc_sdb:result(DBH),
          korrpc_sdb:close(DBH),
          Result;
        {error, enoent} ->
          undefined;
        {error, Reason} ->
          {error, Reason}
      end
  end.

%% @doc Follow stream of records returned by the job.
%%
%%   Caller will receive a sequence of {@type {record, korrpcdid:job_id(),
%%   Id :: non_neg_integer(), korrpc:stream_record()@}} messages, ended with
%%   {@type {terminated, korrpcdid:job_id(), cancelled | Result@}}, where
%%   `Result' has the same form and meaning as returned value of {@link
%%   korrpc:recv/1}.

-spec follow_stream(korrpcdid:job_id()) ->
  ok | undefined.

follow_stream(JobID) ->
  request(JobID, {follow, self()}).

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start caller process.

start(Procedure, ProcArgs, Host, Options) ->
  {ok, Pid} = gen_server:start(?MODULE, [], []),
  % make the process crash on severe operational error (SDB opening error)
  {ok, JobID} =
    gen_server:call(Pid, {start_call, Procedure, ProcArgs, Host, Options}),
  {ok, Pid, JobID}.

%% @private
%% @doc Start caller process.

start_link(Procedure, ProcArgs, Host, Options) ->
  {ok, Pid} = gen_server:start_link(?MODULE, [], []),
  % make the process crash on severe operational error (SDB opening error)
  {ok, JobID} =
    gen_server:call(Pid, {start_call, Procedure, ProcArgs, Host, Options}),
  {ok, Pid, JobID}.

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init([] = _Args) ->
  JobID = korrpcdid:generate_job_id(),
  ets:insert(?ETS_REGISTRY_TABLE, {JobID, self()}),
  Followers = ets:new(followers, [set]),
  State = #state{
    job_id = JobID,
    followers = Followers
  },
  {ok, State}.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{job_id = JobID, followers = Followers,
                                stream_table = StreamTable}) ->
  ets:delete(?ETS_REGISTRY_TABLE, JobID),
  ets:delete(Followers),
  case StreamTable of
    undefined -> ok;
    _ -> korrpc_sdb:close(StreamTable)
  end,
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call({start_call, Procedure, ProcArgs, Host, Options} = _Request, _From,
            State = #state{job_id = JobID, call = undefined}) ->
  {Port, Timeout, MaxExecTime} = decode_options(Options),
  case korrpc_sdb:new(JobID, Procedure, ProcArgs, {Host, Port}) of
    {ok, StreamTable} ->
      case korrpc:request(Procedure, ProcArgs, [{host, Host}, {port, Port}]) of
        {ok, Handle} ->
          Now = now(),
          NewState = State#state{
            stream_table = StreamTable,
            call = Handle,
            start_time = Now,
            last_read = Now,
            max_exec_time = MaxExecTime,
            timeout = Timeout
          },
          {reply, {ok, JobID}, NewState, 0};
        {error, Reason} ->
          korrpc_sdb:set_result(StreamTable, {error, Reason}),
          NewState = State#state{stream_table = StreamTable},
          % request itself failed, but the job was carried successfully; tell
          % the parent that that part got done
          {stop, {call, Reason}, {ok, JobID}, NewState}
      end;
    {error, Reason} ->
      % operational and (mostly) unexpected error; signal crashing
      StopReason = {open, Reason},
      {stop, StopReason, {error, StopReason}, State}
  end;

handle_call({follow, Pid} = _Request, _From,
            State = #state{followers = Followers}) ->
  Ref = erlang:monitor(process, Pid),
  ets:insert(Followers, {Pid, Ref}),
  {reply, ok, State, 0};

handle_call(get_sdb = _Request, _From,
            State = #state{stream_table = StreamTable}) ->
  {reply, {ok, StreamTable}, State, 0};

handle_call(cancel = _Request, _From,
            State = #state{stream_table = StreamTable, job_id = JobID}) ->
  notify_followers(State, {terminated, JobID, cancelled}),
  korrpc_sdb:set_result(StreamTable, cancelled),
  {stop, normal, ok, State};

%% unknown calls
handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

%% unknown casts
handle_cast(_Request, State) ->
  {noreply, State}.

%% @private
%% @doc Handle incoming messages.

handle_info({'DOWN', Ref, process, Pid, _Reason} = _Message,
            State = #state{followers = Followers}) ->
  ets:delete_object(Followers, {Pid, Ref}),
  {noreply, State, 0};

handle_info(timeout = _Message,
            State = #state{call = Handle, stream_table = StreamTable,
                           job_id = JobID, count = Count}) ->
  case korrpc:recv(Handle, ?RPC_READ_INTERVAL) of
    timeout ->
      % NOTE: we need a monotonic clock, so `erlang:now()' is the way to go
      Now = erlang:now(),
      % timer:now_diff() returns microseconds; make it milliseconds
      ReadTime = timer:now_diff(Now, State#state.last_read)  div 1000,
      RunTime  = timer:now_diff(Now, State#state.start_time) div 1000,
      case State of
        % `ReadTime < infinity' for all integers
        #state{timeout = Timeout} when ReadTime >= Timeout ->
          TimeoutDesc = {<<"timeout">>, <<"reading result timed out">>},
          notify_followers(State, {terminated, JobID, {error, TimeoutDesc}}),
          ok = korrpc_sdb:set_result(StreamTable, {error, TimeoutDesc}),
          {stop, normal, State};
        #state{max_exec_time = MaxExecTime} when RunTime >= MaxExecTime ->
          TimeoutDesc = {<<"timeout">>, <<"maximum execution time exceeded">>},
          notify_followers(State, {terminated, JobID, {error, TimeoutDesc}}),
          ok = korrpc_sdb:set_result(StreamTable, {error, TimeoutDesc}),
          {stop, normal, State};
        _ ->
          {noreply, State, 0}
      end;
    {packet, Packet} ->
      notify_followers(State, {record, JobID, Count, Packet}),
      ok = korrpc_sdb:insert(StreamTable, Packet),
      NewState = State#state{count = Count + 1, last_read = now()},
      {noreply, NewState, 0};
    {result, Result} ->
      notify_followers(State, {terminated, JobID, {return, Result}}),
      ok = korrpc_sdb:set_result(StreamTable, {return, Result}),
      {stop, normal, State};
    {exception, Exception} ->
      notify_followers(State, {terminated, JobID, {exception, Exception}}),
      ok = korrpc_sdb:set_result(StreamTable, {exception, Exception}),
      {stop, normal, State};
    {error, Reason} ->
      notify_followers(State, {terminated, JobID, {error, Reason}}),
      ok = korrpc_sdb:set_result(StreamTable, {error, Reason}),
      {stop, normal, State}
  end;

%% unknown messages
handle_info(_Message, State) ->
  {noreply, State}.

%% }}}
%%----------------------------------------------------------
%% code change {{{

%% @private
%% @doc Handle code change.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------

-spec decode_options([call_option()]) ->
  {Port :: inet:port_number(), Timeout :: timeout(), MaxExecTime :: timeout()}.

decode_options(Options) ->
  Port = proplists:get_value(port, Options, 1638),
  T = proplists:get_value(timeout, Options),
  {ok, TA} = application:get_env(default_timeout),
  E = proplists:get_value(max_exec_time, Options),
  {ok, EA} = application:get_env(max_exec_time),
  Timeout = case {T, TA} of
    {undefined, _}      -> TA * 1000;
    {infinity, _}       -> T; % effect limited by `MaxExecTime' anyway
    {_, _} when T  > TA -> TA * 1000;
    {_, _} when T =< TA -> T  * 1000
  end,
  MaxExecTime = case {E, EA} of
    {undefined, _}      -> EA * 1000;
    {infinity, _}       -> EA * 1000;
    {_, _} when E  > EA -> EA * 1000;
    {_, _} when E =< EA -> E  * 1000
  end,
  {Port, Timeout, MaxExecTime}.

notify_followers(_State = #state{followers = Followers}, Message) ->
  ets:foldl(fun send_message/2, Message, Followers),
  ok.

send_message({Pid, _Ref} = _Entry, Message) ->
  Pid ! Message,
  % `Message' is actually an accumulator, but it works well this way
  Message.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
