%%%----------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Remote procedure calling process.
%%%   Process running this module calls remote procedure, receives whatever it
%%%   returns (both end result and streamed response), and records it in
%%%   {@link korrpc_sdb}.
%%% @end
%%%----------------------------------------------------------------------------

-module(korrpcdid_caller).

-behaviour(gen_server).

%% supervision tree API
-export([start/4, start_link/4]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-record(state, {
  job_id,
  stream_table
}).

-include("korrpcdid_caller.hrl").

% }}}
%%%---------------------------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start caller process.

start(Procedure, ProcArgs, Host, Port) ->
  JobID = korrpc_uuid:format(korrpc_uuid:uuid()),
  Args = [JobID, Procedure, ProcArgs, Host, Port],
  case gen_server:start(?MODULE, Args, []) of
    {ok, Pid} -> {ok, Pid, JobID};
    {error, Reason} -> {error, Reason}
  end.

%% @private
%% @doc Start caller process.

start_link(Procedure, ProcArgs, Host, Port) ->
  JobID = korrpc_uuid:format(korrpc_uuid:uuid()),
  Args = [JobID, Procedure, ProcArgs, Host, Port],
  case gen_server:start_link(?MODULE, Args, []) of
    {ok, Pid} -> {ok, Pid, JobID};
    {error, Reason} -> {error, Reason}
  end.

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init([JobID, Procedure, ProcArgs, Host, Port] = _Args) ->
  % TODO: use `[Procedure, ProcArgs, Host, Port]' some other way
  {ok, StreamTable} = korrpc_sdb:new(JobID, Procedure, ProcArgs, {Host, Port}),
  ets:insert(?ETS_REGISTRY_TABLE, {JobID, self()}),
  State = #state{
    job_id = JobID,
    stream_table = StreamTable
  },
  {ok, State}.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{job_id = JobID, stream_table = StreamTable}) ->
  ets:delete(?ETS_REGISTRY_TABLE, JobID),
  korrpc_sdb:close(StreamTable),
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

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
