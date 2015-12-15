%%%---------------------------------------------------------------------------
%%% @doc
%%%   Client connection worker initializer.
%%%   A process running this module reads a single JSON message from its TCP
%%%   client, parses it as a request and either responds to the request when
%%%   it's result is immediate, or switches the running module to the
%%%   appropriate module to carry it out.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_tcp_worker).

-behaviour(gen_server).

%% supervision tree API
-export([start/1, start_link/1]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-define(TCP_READ_INTERVAL, 100).

-record(state, {socket}).

-type request_call() ::
  {call,
    Procedure :: binary(),
    Arguments :: korrpc_json:jarray() | korrpc_json:jhash(),
    Host :: binary(),
    Timeout :: timeout(),
    MaxExecTime :: timeout()}.

-type request_cancel() :: {cancel, korrpcdid:job_id()}.

-type request_get_result() :: {get_result, korrpcdid:job_id(), wait | no_wait}.

-type request_follow_stream() ::
    {follow_stream, korrpcdid:job_id(), since, non_neg_integer()}
  | {follow_stream, korrpcdid:job_id(), recent, non_neg_integer()}.

-type request_read_stream() ::
    {read_stream, korrpcdid:job_id(), since, non_neg_integer()}
  | {read_stream, korrpcdid:job_id(), recent, non_neg_integer()}.

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start worker process.

start(Socket) ->
  gen_server:start(?MODULE, [Socket], []).

%% @private
%% @doc Start worker process.

start_link(Socket) ->
  gen_server:start_link(?MODULE, [Socket], []).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init([Socket] = _Args) ->
  % we can't read the request here, as parent supervisor waits init() to
  % return
  inet:setopts(Socket, [binary, {packet, line}, {active, false}]),
  State = #state{
    socket = Socket
  },
  {ok, State, 0}.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{socket = Socket}) ->
  gen_tcp:close(Socket),
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

handle_info(timeout = _Message, State = #state{socket = Socket}) ->
  case read_request(Socket, ?TCP_READ_INTERVAL) of
    {call, Proc, Args, Host, _Timeout, _MaxExecTime} -> % long running
      put('$worker_function', call),
      % TODO: use `Timeout' and `MaxExecTime'
      % TODO: allow non-default port to be used
      {ok, _Pid, JobID} = korrpcdid_caller:call(Proc, Args, Host),
      send_response(Socket, [
        {<<"korrpcdid">>, 1},
        {<<"job_id">>, list_to_binary(JobID)}
      ]),
      {stop, normal, State};
    {cancel, _JobID} -> % immediate
      put('$worker_function', cancel),
      % TODO: find appropriate call worker, send it cancellation
      {noreply, State, 0};
    {get_result, _JobID, wait} -> % long running
      put('$worker_function', get_result),
      % TODO: gen_server:enter_loop(korrpcdid_tcp_worker_call)
      {noreply, State, 0};
    {get_result, _JobID, no_wait} -> % immediate
      put('$worker_function', get_result),
      % TODO: read from korrpc_sdb
      {noreply, State, 0};
    {follow_stream, _JobID, _Mode, _ModeArg} -> % long running
      put('$worker_function', follow_stream),
      % TODO: gen_server:enter_loop(korrpcdid_tcp_worker_call)
      {noreply, State, 0};
    {read_stream, _JobID, _Mode, _ModeArg} -> % immediate
      % TODO: read from korrpc_sdb
      put('$worker_function', read_stream),
      {noreply, State, 0};
    timeout ->
      % yield for next system message if any awaits our attention
      {noreply, State, 0};
    {error, Reason} ->
      {stop, Reason, State}
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

%% @doc Read a request from TCP socket.

-spec read_request(gen_tcp:socket(), timeout()) ->
    request_call()
  | request_cancel()
  | request_get_result()
  | request_follow_stream()
  | request_read_stream()
  | timeout
  | {error, term()}.

read_request(Socket, Timeout) ->
  case gen_tcp:recv(Socket, 0, Timeout) of
    {ok, Line} ->
      try
        decode_request(Line)
      catch
        error:{badmatch,_}    -> {error, bad_protocol};
        error:{case_clause,_} -> {error, bad_protocol}
      end;
    {error, timeout} ->
      timeout;
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Decode string into a request.
%%
%%   Function dies (`badmatch' or `case_clause') when the request is
%%   malformed.

-spec decode_request(binary()) ->
    request_call()
  | request_cancel()
  | request_get_result()
  | request_follow_stream()
  | request_read_stream()
  | no_return().

decode_request(Line) ->
  % decoded object is supposed to be a JSON hash
  {ok, [{_,_} | _] = Request} = korrpc_json:decode(Line),
  {ok, 1} = orddict:find(<<"korrpcdid">>, Request),
  Request1 = orddict:erase(<<"korrpcdid">>, Request),
  case Request1 of
    [{<<"arguments">>, Args}, {<<"host">>, Host},
      {<<"procedure">>, Procedure}] ->
      {call, Procedure, Args, Host, undefined, undefined};
    [{<<"arguments">>, Args}, {<<"host">>, Host},
      {<<"procedure">>, Procedure}, {<<"timeout">>, Timeout}] ->
      {call, Procedure, Args, Host, Timeout, undefined};
    [{<<"arguments">>, Args}, {<<"host">>, Host},
      {<<"max_exec_time">>, MaxExecTime}, {<<"procedure">>, Procedure}] ->
      {call, Procedure, Args, Host, undefined, MaxExecTime};
    [{<<"arguments">>, Args}, {<<"host">>, Host},
      {<<"max_exec_time">>, MaxExecTime}, {<<"procedure">>, Procedure},
      {<<"timeout">>, Timeout}] ->
      {call, Procedure, Args, Host, Timeout, MaxExecTime};

    [{<<"cancel">>, JobID}] ->
      {cancel, binary_to_list(JobID)};

    [{<<"get_result">>, JobID}] ->
      {get_result, binary_to_list(JobID), no_wait};
    [{<<"get_result">>, JobID}, {<<"wait">>, false}] ->
      {get_result, binary_to_list(JobID), no_wait};
    [{<<"get_result">>, JobID}, {<<"wait">>, true}] ->
      {get_result, binary_to_list(JobID), wait};

    [{<<"follow_stream">>, JobID}] ->
      % XXX: `recent 0', as specified in the protocol; different from
      % `read_stream'
      {follow_stream, binary_to_list(JobID), recent, 0};
    [{<<"follow_stream">>, JobID}, {<<"recent">>, RecentCount}] ->
      {follow_stream, binary_to_list(JobID), recent, RecentCount};
    [{<<"follow_stream">>, JobID}, {<<"since">>, Since}] ->
      {follow_stream, binary_to_list(JobID), since, Since};

    [{<<"read_stream">>, JobID}] ->
      % XXX: `since 0', as specified in the protocol; different from
      % `follow_stream'
      {read_stream, binary_to_list(JobID), since, 0};
    [{<<"read_stream">>, JobID}, {<<"recent">>, RecentCount}] ->
      {read_stream, binary_to_list(JobID), recent, RecentCount};
    [{<<"read_stream">>, JobID}, {<<"since">>, Since}] ->
      {read_stream, binary_to_list(JobID), since, Since}
  end.

%% @doc Encode a structure and send it as a response to client.

-spec send_response(gen_tcp:socket(), korrpc_json:jhash()) ->
  ok.

send_response(Socket, Response) ->
  {ok, Line} = korrpc_json:encode(Response),
  ok = gen_tcp:send(Socket, [Line, $\n]),
  ok.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
