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

-record(state, {
  job_id       :: korrpcdid:job_id(),
  stream_table :: korrpc_sdb:handle(),
  call         :: korrpc:handle(),
  followers    :: ets:tab()
}).

-include("korrpcdid_caller.hrl").

-define(RPC_READ_INTERVAL, 100).

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
  call(Procedure, Args, Host, 1638).

%% @doc Spawn a (supervised) caller process to call remote procedure.

-spec call(korrpc:procedure(), [korrpc:argument()],
           inet:hostname() | inet:ip_address() | binary(),
           inet:port_number()) ->
  {ok, pid(), korrpcdid:job_id()} | {error, term()}.

call(Procedure, Args, Host, Port) when is_binary(Host) ->
  call(Procedure, Args, binary_to_list(Host), Port);
call(Procedure, Args, Host, Port) ->
  korrpcdid_caller_sup:spawn_caller(Procedure, Args, Host, Port).

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
%%
%% @todo Open {@link korrpc_sdb} if no process under `JobID' was present.

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
    {ok, StreamTable} -> korrpc_sdb:result(StreamTable);
    undefined -> undefined
  end.

%% @doc Follow stream of records returned by the job.
%%
%%   Caller will receive a sequence of {@type {record, korrpcdid:job_id(),
%%   korrpc:stream_record()@}} messages, ended with {@type {terminated,
%%   korrpcdid:job_id(), cancelled | Result@}}, where `Result' has the same
%%   form and meaning as returned value of {@link korrpc:recv/1}.

-spec follow_stream(korrpcdid:job_id()) ->
  ok | undefined.

follow_stream(JobID) ->
  request(JobID, {follow, self()}).

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start caller process.

start(Procedure, ProcArgs, Host, Port) ->
  {ok, Pid} = gen_server:start(?MODULE, [], []),
  case gen_server:call(Pid, {start_call, Procedure, ProcArgs, Host, Port}) of
    {ok, JobID} -> {ok, Pid, JobID};
    {error, Reason} -> {error, Reason}
  end.

%% @private
%% @doc Start caller process.

start_link(Procedure, ProcArgs, Host, Port) ->
  {ok, Pid} = gen_server:start_link(?MODULE, [], []),
  case gen_server:call(Pid, {start_call, Procedure, ProcArgs, Host, Port}) of
    {ok, JobID} -> {ok, Pid, JobID};
    {error, Reason} -> {error, Reason}
  end.

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

handle_call({start_call, Procedure, ProcArgs, Host, Port} = _Request, _From,
            State = #state{job_id = JobID, call = undefined}) ->
  case korrpc_sdb:new(JobID, Procedure, ProcArgs, {Host, Port}) of
    {ok, StreamTable} ->
      case korrpc:request(Procedure, ProcArgs, [{host, Host}, {port, Port}]) of
        {ok, Handle} ->
          NewState = State#state{
            stream_table = StreamTable,
            call = Handle
          },
          {reply, {ok, JobID}, NewState, 0};
        {error, Reason} ->
          korrpc_sdb:close(StreamTable),
          StopReason = {call, Reason},
          {stop, StopReason, {error, StopReason}, State}
      end;
    {error, Reason} ->
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
                           job_id = JobID}) ->
  case korrpc:recv(Handle, ?RPC_READ_INTERVAL) of
    timeout ->
      {noreply, State, 0};
    {packet, Packet} ->
      notify_followers(State, {record, JobID, Packet}),
      ok = korrpc_sdb:insert(StreamTable, Packet),
      {noreply, State, 0};
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

notify_followers(_State = #state{followers = Followers}, Message) ->
  ets:foldl(fun send_message/2, Message, Followers),
  ok.

send_message({Pid, _Ref} = _Entry, Message) ->
  Pid ! Message,
  % `Message' is actually an accumulator, but it works well this way
  Message.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
