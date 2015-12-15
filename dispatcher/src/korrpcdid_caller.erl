%%%----------------------------------------------------------------------------
%%% @doc
%%%   Remote procedure calling process.
%%%   Process running this module calls remote procedure, receives whatever it
%%%   returns (both end result and streamed response), and records it in
%%%   {@link korrpc_sdb}.
%%%
%%% @todo Stream followers
%%% @end
%%%----------------------------------------------------------------------------

-module(korrpcdid_caller).

-behaviour(gen_server).

%% public interface
-export([call/3, call/4, locate/1]).

%% supervision tree API
-export([start/4, start_link/4]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-record(state, {
  job_id       :: korrpcdid_tcp_worker:job_id(),
  stream_table :: korrpc_sdb:table(),
  call         :: korrpc:handle()
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
  {ok, pid(), korrpcdid_tcp_worker:job_id()} | {error, term()}.

call(Procedure, Args, Host) ->
  call(Procedure, Args, Host, 1638).

%% @doc Spawn a (supervised) caller process to call remote procedure.

-spec call(korrpc:procedure(), [korrpc:argument()],
           inet:hostname() | inet:ip_address() | binary(), inet:port_number()) ->
  {ok, pid(), korrpcdid_tcp_worker:job_id()} | {error, term()}.

call(Procedure, Args, Host, Port) when is_binary(Host) ->
  call(Procedure, Args, binary_to_list(Host), Port);
call(Procedure, Args, Host, Port) ->
  korrpcdid_caller_sup:spawn_caller(Procedure, Args, Host, Port).

%% @doc Locate the process that carries out specified job ID.

-spec locate(korrpcdid_tcp_worker:job_id()) ->
  {ok, pid()} | none.

locate(JobID) when is_list(JobID) ->
  case ets:lookup(?ETS_REGISTRY_TABLE, JobID) of
    [{JobID, Pid}] -> {ok, Pid};
    [] -> none
  end.

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
  JobID = korrpc_uuid:format(korrpc_uuid:uuid()),
  ets:insert(?ETS_REGISTRY_TABLE, {JobID, self()}),
  State = #state{
    job_id = JobID
  },
  {ok, State}.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{job_id = JobID, stream_table = undefined}) ->
  ets:delete(?ETS_REGISTRY_TABLE, JobID),
  ok;
terminate(_Arg, _State = #state{job_id = JobID, stream_table = StreamTable}) ->
  ets:delete(?ETS_REGISTRY_TABLE, JobID),
  korrpc_sdb:close(StreamTable),
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
          io:fwrite("%% ~p request sent~n", [self()]),
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

handle_info(timeout = _Message,
            State = #state{call = Handle, stream_table = StreamTable}) ->
  case korrpc:recv(Handle, ?RPC_READ_INTERVAL) of
    timeout ->
      {noreply, State, 0};
    {packet, Packet} ->
      io:fwrite("%% ~p got packet: ~1024p~n", [self(), Packet]),
      ok = korrpc_sdb:insert(StreamTable, Packet),
      {noreply, State, 0};
    {result, Result} ->
      io:fwrite("%% ~p return ~1024p~n", [self(), Result]),
      ok = korrpc_sdb:set_result(StreamTable, {return, Result}),
      {stop, normal, State};
    {exception, Exception} ->
      io:fwrite("%% ~p exception! ~1024p~n", [self(), Exception]),
      ok = korrpc_sdb:set_result(StreamTable, {exception, Exception}),
      {stop, normal, State};
    {error, Reason} ->
      io:fwrite("%% ~p error: ~1024p~n", [self(), Reason]),
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
%%% vim:ft=erlang:foldmethod=marker
