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

-define(LOG_CAT, connection).

-define(TCP_READ_INTERVAL, 100).

-record(state, {socket}).

-type request_call() ::
  {call,
    Procedure :: binary(),
    Arguments :: korrpc_json:jarray() | korrpc_json:jhash(),
    Host :: binary(),
    Timeout :: timeout() | undefined,
    MaxExecTime :: timeout() | undefined,
    QueueSpec :: {Name :: korrpc_json:jhash(), Concurrency :: pos_integer()} |
                 undefined}.

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
  {ok, {_PeerAddr, _PeerPort} = Peer} = inet:peername(Socket),
  case read_request(Socket, ?TCP_READ_INTERVAL) of
    {call, Proc, Args, Host, Timeout, MaxExecTime, Queue} -> % long running
      put('$worker_function', call),
      korrpcdid_log:info(?LOG_CAT, "call request",
                         [{client, {term, Peer}},
                          {host, Host},
                          {procedure, Proc}, {procedure_arguments, Args},
                          {timeout, Timeout}, {max_exec_time, MaxExecTime},
                          {queue, queue_log_info(Queue)}]),
      Options = case {Timeout, MaxExecTime} of
        {undefined, undefined} ->
          [];
        {_, undefined} when is_integer(Timeout) ->
          [{timeout, Timeout}];
        {undefined, _} when is_integer(MaxExecTime) ->
          [{max_exec_time, MaxExecTime}];
        {_, _} when is_integer(Timeout), is_integer(MaxExecTime) ->
          [{timeout, Timeout}, {max_exec_time, MaxExecTime}]
      end,
      QueueOpts = case Queue of
        undefined -> [];
        {QueueName, Concurrency} -> [{queue, {QueueName, Concurrency}}]
      end,
      {ok, _Pid, JobID} =
        korrpcdid_caller:call(Proc, Args, Host, QueueOpts ++ Options),
      send_response(Socket, [
        {<<"korrpcdid">>, 1},
        {<<"job_id">>, list_to_binary(JobID)}
      ]),
      {stop, normal, State};
    {cancel, JobID} -> % immediate
      put('$worker_function', cancel),
      korrpcdid_log:info(?LOG_CAT, "cancel job",
                         [{client, {term, Peer}}, {job, {str, JobID}}]),
      case korrpcdid_caller:cancel(JobID) of
        ok        -> send_response(Socket, [{<<"cancelled">>, true}]);
        undefined -> send_response(Socket, [{<<"cancelled">>, false}])
      end,
      {stop, normal, State};
    {get_result, JobID, Mode} -> % long running or immediate, depending on mode
      put('$worker_function', get_result),
      Wait = case Mode of
        wait -> true;
        no_wait -> false
      end,
      korrpcdid_log:info(?LOG_CAT, "get job's result",
                         [{client, {term, Peer}}, {job, {str, JobID}},
                          {wait, Wait}]),
      NewState = korrpcdid_tcp_return_result:state(Socket, JobID, Wait),
      % this does not return to this code
      gen_server:enter_loop(korrpcdid_tcp_return_result, [], NewState, 0);
    {follow_stream, JobID, Mode, ModeArg} -> % long running
      % `Mode :: recent | since'
      put('$worker_function', follow_stream),
      korrpcdid_log:info(?LOG_CAT, "follow job's streamed result",
                         [{client, {term, Peer}}, {job, {str, JobID}}]),
      NewState = korrpcdid_tcp_return_stream:state(Socket, JobID, follow, {Mode, ModeArg}),
      % this does not return to this code
      gen_server:enter_loop(korrpcdid_tcp_return_stream, [], NewState, 0);
    {read_stream, JobID, Mode, ModeArg} -> % immediate
      % `Mode :: recent | since'
      put('$worker_function', read_stream),
      korrpcdid_log:info(?LOG_CAT, "follow job's streamed result",
                         [{client, {term, Peer}}, {job, {str, JobID}}]),
      NewState = korrpcdid_tcp_return_stream:state(Socket, JobID, read, {Mode, ModeArg}),
      % this does not return to this code
      gen_server:enter_loop(korrpcdid_tcp_return_stream, [], NewState, 0);
    timeout ->
      % yield for next system message if any awaits our attention
      {noreply, State, 0};
    {error, Reason} ->
      korrpcdid_log:warn(?LOG_CAT, "request reading error",
                         [{client, {term, Peer}}, {reason, {term, Reason}}]),
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
        error:{case_clause,_} -> {error, bad_protocol};
        error:badarg          -> {error, bad_protocol}
      end;
    {error, timeout} ->
      timeout;
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Decode string into a request.
%%
%%   Function dies (`badmatch', `case_clause', or `badarg') when the request
%%   is malformed.

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
    % unqueued calls
    [{<<"arguments">>, Args}, {<<"host">>, Host},
      {<<"procedure">>, Procedure}] ->
      {call, Procedure, Args, Host, undefined, undefined, undefined};
    [{<<"arguments">>, Args}, {<<"host">>, Host},
      {<<"procedure">>, Procedure}, {<<"timeout">>, Timeout}] ->
      {call, Procedure, Args, Host, Timeout, undefined, undefined};
    [{<<"arguments">>, Args}, {<<"host">>, Host},
      {<<"max_exec_time">>, MaxExecTime}, {<<"procedure">>, Procedure}] ->
      {call, Procedure, Args, Host, undefined, MaxExecTime, undefined};
    [{<<"arguments">>, Args}, {<<"host">>, Host},
      {<<"max_exec_time">>, MaxExecTime}, {<<"procedure">>, Procedure},
      {<<"timeout">>, Timeout}] ->
      {call, Procedure, Args, Host, Timeout, MaxExecTime, undefined};
    % queued calls
    [{<<"arguments">>, Args}, {<<"host">>, Host},
      {<<"procedure">>, Procedure},
      {<<"queue">>, QueueSpec}] ->
      {call, Procedure, Args, Host, undefined, undefined,
        parse_queue_spec(QueueSpec)};
    [{<<"arguments">>, Args}, {<<"host">>, Host},
      {<<"procedure">>, Procedure},
      {<<"queue">>, QueueSpec}, {<<"timeout">>, Timeout}] ->
      {call, Procedure, Args, Host, Timeout, undefined,
        parse_queue_spec(QueueSpec)};
    [{<<"arguments">>, Args}, {<<"host">>, Host},
      {<<"max_exec_time">>, MaxExecTime}, {<<"procedure">>, Procedure},
      {<<"queue">>, QueueSpec}] ->
      {call, Procedure, Args, Host, undefined, MaxExecTime,
        parse_queue_spec(QueueSpec)};
    [{<<"arguments">>, Args}, {<<"host">>, Host},
      {<<"max_exec_time">>, MaxExecTime}, {<<"procedure">>, Procedure},
      {<<"queue">>, QueueSpec}, {<<"timeout">>, Timeout}] ->
      {call, Procedure, Args, Host, Timeout, MaxExecTime,
        parse_queue_spec(QueueSpec)};

    [{<<"cancel">>, JobID}] ->
      {cancel, convert_job_id(JobID)};

    [{<<"get_result">>, JobID}] ->
      {get_result, convert_job_id(JobID), no_wait};
    [{<<"get_result">>, JobID}, {<<"wait">>, false}] ->
      {get_result, convert_job_id(JobID), no_wait};
    [{<<"get_result">>, JobID}, {<<"wait">>, true}] ->
      {get_result, convert_job_id(JobID), wait};

    [{<<"follow_stream">>, JobID}] ->
      % XXX: `recent 0', as specified in the protocol; different from
      % `read_stream'
      {follow_stream, convert_job_id(JobID), recent, 0};
    [{<<"follow_stream">>, JobID}, {<<"recent">>, RecentCount}] ->
      {follow_stream, convert_job_id(JobID), recent, RecentCount};
    [{<<"follow_stream">>, JobID}, {<<"since">>, Since}] ->
      {follow_stream, convert_job_id(JobID), since, Since};

    [{<<"read_stream">>, JobID}] ->
      % XXX: `since 0', as specified in the protocol; different from
      % `follow_stream'
      {read_stream, convert_job_id(JobID), since, 0};
    [{<<"read_stream">>, JobID}, {<<"recent">>, RecentCount}] ->
      {read_stream, convert_job_id(JobID), recent, RecentCount};
    [{<<"read_stream">>, JobID}, {<<"since">>, Since}] ->
      {read_stream, convert_job_id(JobID), since, Since}
  end.

%% @doc Ensure the passed job ID is of proper (string) format.
%%   If it is invalid, returned value will be an almost proper job ID, and
%%   a one that will never be generated by this system.

-spec convert_job_id(korrpc_json:struct()) ->
  korrpcdid:job_id().

convert_job_id(JobID) when is_binary(JobID) ->
  convert_job_id(binary_to_list(JobID));
convert_job_id(JobID) when is_list(JobID) ->
  case korrpcdid:valid_job_id(JobID) of
    true -> JobID;
    false -> "00000000-0000-0000-0000-000000000000"
  end;
convert_job_id(_JobID) ->
  "00000000-0000-0000-0000-000000000000".

%% @doc Parse queue specification from request.

-spec parse_queue_spec(korrpc_json:jhash()) ->
  {korrpc_json:jhash(), pos_integer()} | no_return().

parse_queue_spec([{<<"concurrency">>, C},
                   {<<"name">>, [{_,_}|_] = QueueName}] = _QueueSpec)
when is_integer(C), C > 0 ->
  {QueueName, C};
parse_queue_spec([{<<"concurrency">>, C},
                   {<<"name">>, [{}] = QueueName}] = _QueueSpec)
when is_integer(C), C > 0 ->
  {QueueName, C};
parse_queue_spec([{<<"name">>, [{_,_}|_] = QueueName}] = _QueueSpec) ->
  {QueueName, 1};
parse_queue_spec([{<<"name">>, [{}] = QueueName}] = _QueueSpec) ->
  {QueueName, 1}.

%% @doc Encode a structure and send it as a response to client.

-spec send_response(gen_tcp:socket(), korrpc_json:jhash()) ->
  ok.

send_response(Socket, Response) ->
  {ok, Line} = korrpc_json:encode(Response),
  ok = gen_tcp:send(Socket, [Line, $\n]),
  ok.

%% @doc Encode queue specification as a JSON-serializable object.

-spec queue_log_info({korrpc_json:jhash(), pos_integer()} | undefined) ->
  korrpc_json:jhash() | null.

queue_log_info({QueueName, QueueConcurrency} = _QueueSpec) ->
  [{name, QueueName}, {concurrency, QueueConcurrency}];
queue_log_info(undefined = _QueueSpec) ->
  null.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
