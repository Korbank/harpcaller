%%%---------------------------------------------------------------------------
%%% @doc
%%%   Client connection worker initializer.
%%%   A process running this module reads a single JSON message from its TCP
%%%   client, parses it as a request and either responds to the request when
%%%   it's result is immediate, or switches the running module to the
%%%   appropriate module to carry it out.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_tcp_worker).

-behaviour(gen_server).

%% public interface
-export([take_over/1]).

%% supervision tree API
-export([start/1, start_link/1]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-record(state, {socket}).

-record(req, {
  protocol :: undefined | pos_integer(),
  op :: atom(),
  args = [] :: [term()],
  opts = [] :: [{atom(), term()}]
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Spawn a worker process, taking over a client socket.
%%
%%   The caller must be the controlling process of the `Socket'.
%%
%%   In case of spawning error, the socket is closed. In any case, caller
%%   shouldn't bother with the socket anymore.

-spec take_over(gen_tcp:socket()) ->
  {ok, pid()} | {error, term()}.

take_over(Socket) ->
  case harpcaller_tcp_worker_sup:spawn_worker(Socket) of
    {ok, Pid} ->
      ok = gen_tcp:controlling_process(Socket, Pid),
      {ok, Pid};
    {error, Reason} ->
      gen_tcp:close(Socket),
      {error, Reason}
  end.

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
  % XXX: we can't read the request here, as parent supervisor waits init() to
  % return
  {ok, {PeerAddr, PeerPort}} = inet:peername(Socket),
  {ok, {LocalAddr, LocalPort}} = inet:sockname(Socket),
  harpcaller_log:set_context(connection, [
    {client, {str, format_address(PeerAddr, PeerPort)}},
    {local_address, {str, format_address(LocalAddr, LocalPort)}}
  ]),
  harpcaller_log:info("new connection"),
  inet:setopts(Socket, [binary, {packet, line}, {active, once}]),
  State = #state{
    socket = Socket
  },
  {ok, State}.

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
handle_call(Request, From, State) ->
  harpcaller_log:unexpected_call(Request, From, ?MODULE),
  {reply, {error, unknown_call}, State}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

%% unknown casts
handle_cast(Request, State) ->
  harpcaller_log:unexpected_cast(Request, ?MODULE),
  {noreply, State}.

%% @private
%% @doc Handle incoming messages.

handle_info({tcp, Socket, Line} = _Message,
            State = #state{socket = Socket}) ->
  case decode_request(Line) of
    #req{op = call, args = [Proc, Args, Host], opts = Opts} ->
      put('$worker_function', call),
      {ok, JobID} = execute_call(Proc, Args, Host, Opts),
      send_response(Socket, [
        {<<"harpcaller">>, 1},
        {<<"job_id">>, list_to_binary(JobID)}
      ]),
      {stop, normal, State};
    #req{op = cancel, args = [JobID]} ->
      put('$worker_function', cancel),
      Cancelled = execute_cancel(JobID),
      send_response(Socket, [{<<"cancelled">>, Cancelled}]),
      {stop, normal, State};
    #req{op = get_status, args = [JobID]} ->
      put('$worker_function', get_status),
      case execute_get_status(JobID) of
        {ok, JobStatusStruct} ->
          send_response(Socket, JobStatusStruct);
        undefined ->
          send_response(Socket, [
            {<<"error">>, [
              {<<"type">>, <<"invalid_jobid">>},
              {<<"message">>, <<"no job with this ID">>}
            ]}
          ]);
        {error, Message} ->
          harpcaller_log:warn("job status reading error", [{error, Message}]),
          send_response(Socket, [
            {<<"error">>, [
              {<<"type">>, <<"unrecognized">>},
              {<<"message">>, Message}
            ]}
          ])
      end,
      {stop, normal, State};
    #req{op = get_result, args = [JobID], opts = Opts} ->
      put('$worker_function', get_result),
      % TODO: handle this without calling another module
      {Module, NewState} = execute_get_result(Socket, JobID, Opts),
      gen_server:enter_loop(Module, [], NewState, 0);
    #req{op = follow_stream, args = [JobID], opts = Opts} ->
      put('$worker_function', follow_stream),
      % TODO: handle this without calling another module
      {Module, NewState} = execute_follow_stream(Socket, JobID, Opts),
      gen_server:enter_loop(Module, [], NewState, 0);
    #req{op = read_stream, args = [JobID], opts = Opts} ->
      put('$worker_function', read_stream),
      % TODO: handle this without calling another module
      {Module, NewState} = execute_read_stream(Socket, JobID, Opts),
      gen_server:enter_loop(Module, [], NewState, 0)
  end;

handle_info({tcp_closed, Socket} = _Message,
            State = #state{socket = Socket}) ->
  harpcaller_log:info("no request read"),
  {stop, normal, State};

handle_info({tcp_error, Socket, Reason} = _Message,
            State = #state{socket = Socket}) ->
  harpcaller_log:warn("request reading error", [{error, {term, Reason}}]),
  {stop, normal, State};

%% unknown messages
handle_info(Message, State) ->
  harpcaller_log:unexpected_info(Message, ?MODULE),
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
%%% decode_request() {{{

%% @doc Decode string into a request.

-spec decode_request(binary()) ->
  #req{} | {error, bad_protocol}.

decode_request(Line) ->
  % decoded object is supposed to be a JSON hash
  try decode_request(try_decode_hash(Line), #req{}) of
    #req{protocol = V} when V /= 1 ->
      {error, bad_protocol};
    #req{op = undefined} ->
      {error, bad_protocol};

    Req = #req{op = call, args = [_Procedure, _Args, _Host], opts = _Opts} ->
      Req;

    Req = #req{op = cancel, args = [JobID], opts = []} ->
      Req#req{args = [convert_job_id(JobID)]};

    Req = #req{op = get_result, args = [JobID], opts = []} ->
      Req#req{args = [convert_job_id(JobID)], opts = [{wait, false}]};
    Req = #req{op = get_result, args = [JobID], opts = [{wait, false}]} ->
      Req#req{args = [convert_job_id(JobID)]};
    Req = #req{op = get_result, args = [JobID], opts = [{wait, true}]} ->
      Req#req{args = [convert_job_id(JobID)]};

    Req = #req{op = get_status, args = [JobID], opts = []} ->
      Req#req{args = [convert_job_id(JobID)]};

    Req = #req{op = follow_stream, args = [JobID], opts = []} ->
      % XXX: `recent 0', as specified in the protocol; different from
      % `read_stream'
      Req#req{args = [convert_job_id(JobID)], opts = [{recent, 0}]};
    Req = #req{op = follow_stream, args = [JobID], opts = [{recent, _}]} ->
      Req#req{args = [convert_job_id(JobID)]};
    Req = #req{op = follow_stream, args = [JobID], opts = [{since, _}]} ->
      Req#req{args = [convert_job_id(JobID)]};

    Req = #req{op = read_stream, args = [JobID], opts = []} ->
      % XXX: `since 0', as specified in the protocol; different from
      % `follow_stream'
      Req#req{args = [convert_job_id(JobID)], opts = [{since, 0}]};
    Req = #req{op = read_stream, args = [JobID], opts = [{recent, _}]} ->
      Req#req{args = [convert_job_id(JobID)]};
    Req = #req{op = read_stream, args = [JobID], opts = [{since, _}]} ->
      Req#req{args = [convert_job_id(JobID)]};

    _ ->
      {error, bad_protocol}
  catch
    error:{badmatch,_}    -> {error, bad_protocol};
    error:{case_clause,_} -> {error, bad_protocol};
    error:function_clause -> {error, bad_protocol};
    error:badarg          -> {error, bad_protocol}
  end.

%% @doc Decode a non-empty JSON hash, dying on error.

-spec try_decode_hash(binary()) ->
  harp_json:jhash().

try_decode_hash(Line) ->
  {ok, [{_,_} | _] = Struct} = harp_json:decode(Line),
  Struct.

%% @doc Walk through all the request fields and collect options from them.

-spec decode_request(harp_json:jhash(), #req{}) ->
  #req{}.

decode_request([] = _Struct, Req = #req{}) ->
  Req;

decode_request([{<<"harpcaller">>, V} | Rest], Req = #req{protocol = undefined}) ->
  decode_request(Rest, Req#req{protocol = V});

decode_request([{<<"cancel">>, JobID} | Rest], Req = #req{op = undefined}) ->
  decode_request(Rest, Req#req{op = cancel, args = [JobID]});

decode_request([{<<"get_result">>, JobID} | Rest], Req = #req{op = undefined}) ->
  decode_request(Rest, Req#req{op = get_result, args = [JobID]});

decode_request([{<<"get_status">>, JobID} | Rest], Req = #req{op = undefined}) ->
  decode_request(Rest, Req#req{op = get_status, args = [JobID]});

decode_request([{<<"follow_stream">>, JobID} | Rest], Req = #req{op = undefined}) ->
  decode_request(Rest, Req#req{op = follow_stream, args = [JobID]});

decode_request([{<<"read_stream">>, JobID} | Rest], Req = #req{op = undefined}) ->
  decode_request(Rest, Req#req{op = read_stream, args = [JobID]});

decode_request([{<<"arguments">>, Args} | Rest], Req = #req{op = undefined}) ->
  decode_request(Rest, Req#req{op = call, args = [Args]});
decode_request([{<<"host">>, Host} | Rest], Req = #req{op = call, args = [Args]}) ->
  decode_request(Rest, Req#req{args = [Args, Host]});
decode_request([{<<"procedure">>, Proc} | Rest], Req = #req{op = call, args = [Args, Host]}) ->
  decode_request(Rest, Req#req{args = [Proc, Args, Host]});

decode_request([{<<"timeout">>, Timeout} | Rest], Req = #req{opts = Opts}) ->
  decode_request(Rest, Req#req{opts = [{timeout, Timeout} | Opts]});
decode_request([{<<"max_exec_time">>, MaxExecTime} | Rest], Req = #req{opts = Opts}) ->
  decode_request(Rest, Req#req{opts = [{max_exec_time, MaxExecTime} | Opts]});
decode_request([{<<"queue">>, QueueSpec} | Rest], Req = #req{opts = Opts}) ->
  Queue = case QueueSpec of
    [{<<"concurrency">>, C}, {<<"name">>, [{_,_}|_] = Name}] -> {Name, C};
    [{<<"concurrency">>, C}, {<<"name">>, [{}]      = Name}] -> {Name, C};
    [{<<"name">>, [{_,_}|_] = Name}] -> {Name, 1};
    [{<<"name">>, [{}]      = Name}] -> {Name, 1}
  end,
  decode_request(Rest, Req#req{opts = [{queue, Queue} | Opts]});
decode_request([{<<"info">>, CallInfo} | Rest], Req = #req{opts = Opts}) ->
  decode_request(Rest, Req#req{opts = [{call_info, CallInfo} | Opts]});

decode_request([{<<"recent">>, N} | Rest], Req = #req{opts = Opts}) ->
  decode_request(Rest, Req#req{opts = [{recent, N} | Opts]});
decode_request([{<<"since">>, N} | Rest], Req = #req{opts = Opts}) ->
  decode_request(Rest, Req#req{opts = [{since, N} | Opts]});

decode_request([{<<"wait">>, Wait} | Rest], Req = #req{opts = Opts}) ->
  decode_request(Rest, Req#req{opts = [{wait, Wait} | Opts]}).

%% @doc Ensure the passed job ID is of proper (string) format.
%%   If it is invalid, returned value will be an almost proper job ID, and
%%   a one that will never be generated by this system.

-spec convert_job_id(harp_json:struct()) ->
  harpcaller:job_id().

convert_job_id(JobID) when is_binary(JobID) ->
  convert_job_id(binary_to_list(JobID));
convert_job_id(JobID) when is_list(JobID) ->
  case harpcaller:valid_job_id(JobID) of
    true -> JobID;
    false -> "00000000-0000-0000-0000-000000000000"
  end;
convert_job_id(_JobID) ->
  "00000000-0000-0000-0000-000000000000".

%%% }}}
%%%---------------------------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% handle requests
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% execute_call() {{{

%% @doc Execute call request, returning ID of the spawned call job.

-spec execute_call(binary(), harp_json:jarray() | harp_json:jhash(), binary(),
                   [{atom(), term()}]) ->
  {ok, harpcaller:job_id()}.

execute_call(Proc, Args, Host, Opts) ->
  Timeout = proplists:get_value(timeout, Opts),
  MaxExecTime = proplists:get_value(timeout, Opts),
  Queue = proplists:get_value(queue, Opts),
  CallInfo = proplists:get_value(call_info, Opts, null),
  harpcaller_log:info("call request", [
    % TODO: include `CallInfo' in the log?
    {host, Host}, {procedure, Proc}, {procedure_arguments, Args},
    {timeout, undef_null(Timeout)},
    {max_exec_time, undef_null(MaxExecTime)},
    {queue, format_queue(Queue)}
  ]),
  Options = call_time_options(Timeout, MaxExecTime) ++
            call_queue_options(Queue) ++
            [{call_info, CallInfo}],
  {ok, _Pid, JobID} = harpcaller_caller:call(Proc, Args, Host, Options),
  harpcaller_log:info("call process started", [{job, {str, JobID}}]),
  {ok, JobID}.

%% @doc Build a list of timeout-related call options.

call_time_options(undefined = _Timeout, undefined = _MaxExecTime) ->
  [];
call_time_options(Timeout, undefined = _MaxExecTime) ->
  [{timeout, Timeout}];
call_time_options(undefined = _Timeout, MaxExecTime) ->
  [{max_exec_time, MaxExecTime}];
call_time_options(Timeout, MaxExecTime) ->
  [{timeout, Timeout}, {max_exec_time, MaxExecTime}].

%% @doc Build a list of queue-related options.

call_queue_options(undefined = _Queue) ->
  [];
call_queue_options({QueueName, Concurrency} = _Queue) ->
  [{queue, {QueueName, Concurrency}}].

%% }}}
%%----------------------------------------------------------
%% execute_cancel() {{{

%% @doc Cancel a running job.
%%
%%   Function returns information whether the job was running.

-spec execute_cancel(harpcaller:job_id()) ->
  boolean().

execute_cancel(JobID) ->
  harpcaller_log:info("cancel job", [{job, {str, JobID}}]),
  case harpcaller_caller:cancel(JobID) of
    ok -> true;
    undefined -> false
  end.

%% }}}
%%----------------------------------------------------------
%% execute_get_status() {{{

%% @doc Return information about call job.

-spec execute_get_status(harpcaller:job_id()) ->
  {ok, harp_json:struct()} | undefined | {error, binary()}.

execute_get_status(JobID) ->
  harpcaller_log:append_context([{job, {str, JobID}}]),
  harpcaller_log:info("get job's status"),
  case harpcaller_caller:get_call_info(JobID) of
    {ok, {{ProcName, ProcArgs} = _ProcInfo, Host,
          {SubmitTime, StartTime, EndTime} = _TimeInfo, CallInfo}} ->
      JobStatus = [
        {<<"call">>, [
          {<<"procedure">>, ProcName},
          {<<"arguments">>, ProcArgs},
          {<<"host">>, Host}
        ]},
        {<<"time">>, [
          {<<"submit">>, undef_null(SubmitTime)}, % non-null, but consistency
          {<<"start">>,  undef_null(StartTime)},
          {<<"end">>,    undef_null(EndTime)}
        ]},
        {<<"info">>, CallInfo}
      ],
      {ok, JobStatus};
    undefined ->
      undefined;
    {error, Reason} ->
      {error, iolist_to_binary(io_lib:format("~1024p", [Reason]))}
  end.

%% }}}
%%----------------------------------------------------------
%% execute_get_result() {{{

%% @doc Prepare a {@link gen_server} module and its state for getting job's
%%   end result.

-spec execute_get_result(gen_tcp:socket(), harpcaller:job_id(),
                         [{atom(), term()}]) ->
  {module(), NewState :: term()}.

execute_get_result(Socket, JobID, Opts) ->
  Wait = proplists:get_bool(wait, Opts),
  harpcaller_log:append_context([{job, {str, JobID}}]),
  harpcaller_log:info("get job's result", [{wait, Wait}]),
  NewState = harpcaller_tcp_return_result:state(Socket, JobID, Wait),
  {harpcaller_tcp_return_result, NewState}.

%% }}}
%%----------------------------------------------------------
%% execute_follow_stream() {{{

%% @doc Prepare a {@link gen_server} module and its state for following job's
%%   stream result.

-spec execute_follow_stream(gen_tcp:socket(), harpcaller:job_id(),
                            [{atom(), term()}]) ->
  {module(), NewState :: term()}.

execute_follow_stream(Socket, JobID, Opts) ->
  harpcaller_log:append_context([{job, {str, JobID}}]),
  harpcaller_log:info("follow job's streamed result"),
  case Opts of
    [{since = Mode, N}] -> ok;
    [{recent = Mode, N}] -> ok
  end,
  NewState = harpcaller_tcp_return_stream:state(Socket, JobID, follow,
                                                {Mode, N}),
  {harpcaller_tcp_return_stream, NewState}.

%% }}}
%%----------------------------------------------------------
%% execute_read_stream() {{{

%% @doc Prepare a {@link gen_server} module and its state for reading job's
%%   stream result.

-spec execute_read_stream(gen_tcp:socket(), harpcaller:job_id(),
                          [{atom(), term()}]) ->
  {module(), NewState :: term()}.

execute_read_stream(Socket, JobID, Opts) ->
  harpcaller_log:append_context([{job, {str, JobID}}]),
  harpcaller_log:info("follow job's streamed result"),
  case Opts of
    [{since = Mode, N}] -> ok;
    [{recent = Mode, N}] -> ok
  end,
  NewState = harpcaller_tcp_return_stream:state(Socket, JobID, read,
                                                {Mode, N}),
  {harpcaller_tcp_return_stream, NewState}.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% helper functions
%%%---------------------------------------------------------------------------

%% @doc Encode a structure and send it as a response to client.

-spec send_response(gen_tcp:socket(), harp_json:jhash()) ->
  ok.

send_response(Socket, Response) ->
  {ok, Line} = harp_json:encode(Response),
  ok = gen_tcp:send(Socket, [Line, $\n]),
  ok.

%% @doc Format IP address and port number for logging.

-spec format_address(inet:ip_address(), inet:port_number()) ->
  string().

format_address({A,B,C,D} = _Address, Port) ->
  % TODO: IPv6
  OctetList = [
    integer_to_list(A),
    integer_to_list(B),
    integer_to_list(C),
    integer_to_list(D)
  ],
  string:join(OctetList, ".") ++ ":" ++ integer_to_list(Port).

%% @doc Format queue specification for logging.

-spec format_queue({harp_json:jhash(), pos_integer()} | undefined) ->
  harp_json:jhash() | null.

format_queue({QueueName, QueueConcurrency} = _QueueSpec) ->
  [{name, QueueName}, {concurrency, QueueConcurrency}];
format_queue(undefined = _QueueSpec) ->
  null.

undef_null(undefined = _Value) -> null;
undef_null(Value) -> Value.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
