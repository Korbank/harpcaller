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

-record(req, {
  protocol :: undefined | pos_integer(),
  op :: atom(),
  args = [] :: [term()],
  opts = [] :: [{atom(), term()}]
}).

-record(state, {
  socket :: gen_tcp:socket(),
  request :: #req{} | undefined,
  job_monitor :: reference() | undefined,
  skip_stream :: all | non_neg_integer() | undefined
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

handle_info({record, _JobID, Id, _Record} = _Message,
            State = #state{skip_stream = SkipBefore})
when SkipBefore == all; Id < SkipBefore ->
  {noreply, State};

handle_info({record, _JobID, Id, Record} = _Message,
            State = #state{socket = Socket, skip_stream = SkipBefore})
when SkipBefore == undefined; Id >= SkipBefore ->
  case send_response(Socket, [{<<"packet">>, Id}, {<<"data">>, Record}]) of
    ok -> {noreply, State};
    {error, _Reason} -> {stop, normal, State}
  end;

handle_info({'DOWN', MonRef, process, Pid, Reason} = _Message,
            State = #state{socket = Socket, job_monitor = MonRef}) ->
  % the process carrying out the job died
  harpcaller_log:info("job died",
                      [{pid, {term, Pid}}, {error, {term, Reason}}]),
  send_response(Socket, format_result(missing)),
  {stop, normal, State};

handle_info({terminated, _JobID, Result} = _Message,
            State = #state{socket = Socket}) ->
  % got our result; send it to the client
  harpcaller_log:info("job terminated"),
  send_response(Socket, format_result(Result)),
  {stop, normal, State};

handle_info({tcp, Socket, Line} = _Message,
            State = #state{socket = Socket, request = undefined}) ->
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
    #req{op = get_result, args = [JobID], opts = Opts} = Req ->
      put('$worker_function', get_result),
      case execute_get_result(JobID, Opts) of
        {ok, still_running = _Result} ->
          send_response(Socket, [{<<"no_result">>, true}]),
          {stop, normal, State};
        {ok, Result} ->
          send_response(Socket, format_result(Result)),
          {stop, normal, State};
        {wait, MonRef} ->
          NewState = State#state{
            request = Req,
            skip_stream = all,
            job_monitor = MonRef
          },
          {noreply, NewState}
      end;
    #req{op = follow_stream, args = [JobID], opts = Opts} = Req ->
      put('$worker_function', follow_stream),
      case execute_follow_stream(JobID, Opts) of
        {follow, Handle, Since, MonRef} ->
          harpcaller_log:info("job still running, reading the stream result"),
          SkipUntil = read_and_send_stream_since(Handle, Since, Socket),
          harp_sdb:close(Handle),
          NewState = State#state{
            request = Req,
            skip_stream = SkipUntil,
            job_monitor = MonRef
          },
          {noreply, NewState};
        {terminated, Handle, Since, Result} ->
          harpcaller_log:info("job is already finished, returning result"),
          read_and_send_stream_since(Handle, Since, Socket),
          harp_sdb:close(Handle),
          send_response(Socket, format_result(Result)),
          {stop, normal, State}
      end;
    #req{op = read_stream, args = [JobID], opts = Opts} ->
      put('$worker_function', read_stream),
      {ok, Handle, Since} = execute_read_stream(JobID, Opts),
      read_and_send_stream_since(Handle, Since, Socket),
      case harp_sdb:result(Handle) of
        still_running ->
          send_response(Socket, [{<<"continue">>, true}]);
        Result ->
          send_response(Socket, format_result(Result))
      end,
      harp_sdb:close(Handle),
      {stop, normal, State}
  end;

handle_info({tcp_closed, Socket} = _Message,
            State = #state{socket = Socket, request = undefined}) ->
  harpcaller_log:info("no request read"),
  {stop, normal, State};

handle_info({tcp_error, Socket, Reason} = _Message,
            State = #state{socket = Socket, request = undefined}) ->
  harpcaller_log:warn("request reading error", [{error, {term, Reason}}]),
  {stop, normal, State};

handle_info({tcp, Socket, _Line} = _Message,
            State = #state{socket = Socket, request = #req{}}) ->
  harpcaller_log:warn("unexpected data after reading request"),
  {stop, normal, State};

handle_info({tcp_closed, Socket} = _Message,
            State = #state{socket = Socket, request = #req{}}) ->
  {stop, normal, State};

handle_info({tcp_error, Socket, _Reason} = _Message,
            State = #state{socket = Socket, request = #req{}}) ->
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

-spec execute_get_result(harpcaller:job_id(), [{atom(), term()}]) ->
  {ok, Result} | {wait, Monitor :: reference()}
  when Result :: {return, harp:result()}
               | still_running
               | cancelled
               | missing
               | {exception, harp:error_description()}
               | {error, harp:error_description() | term()}
               | undefined.

execute_get_result(JobID, Opts) ->
  Wait = proplists:get_bool(wait, Opts),
  harpcaller_log:append_context([{job, {str, JobID}}, {wait, Wait}]),
  harpcaller_log:info("get job's result"),
  case Wait of
    true ->
      case harpcaller_caller:follow_stream(JobID) of
        {ok, MonRef} ->
          harpcaller_log:info("job still running, waiting for the result"),
          {wait, MonRef};
        % NOTE: this can't return `still_running', as monitor couldn't be set
        undefined ->
          harpcaller_log:info("returning job's result"),
          {ok, harpcaller_caller:get_result(JobID)}
      end;
    false ->
      harpcaller_log:info("returning job's result"),
      {ok, harpcaller_caller:get_result(JobID)}
  end.

%% }}}
%%----------------------------------------------------------
%% execute_follow_stream() {{{

%% @doc Prepare a {@link gen_server} module and its state for following job's
%%   stream result.

-spec execute_follow_stream(harpcaller:job_id(), [{atom(), term()}]) ->
    {follow, Handle, Since, Monitor}
  | {terminated, Handle, Since, Result}
  when Handle :: harp_sdb:handle(),
       Since :: non_neg_integer(),
       Monitor :: reference(),
       Result :: {return, harp:result()}
               | cancelled
               | missing
               | {exception, harp:error_description()}
               | {error, harp:error_description() | term()}
               | undefined.

execute_follow_stream(JobID, Opts) ->
  harpcaller_log:append_context([{job, {str, JobID}}, {wait, true}]),
  harpcaller_log:info("follow job's streamed result"),
  {ok, Handle} = harp_sdb:load(JobID), % TODO: handle errors
  case Opts of
    [{since, Since}] ->
      ok;
    [{recent, N}] ->
      Since = max(0, harp_sdb:stream_size(Handle) - N)
  end,
  case harpcaller_caller:follow_stream(JobID) of
    {ok, MonRef} ->
      {follow, Handle, Since, MonRef};
    undefined ->
      % XXX: this shouldn't return `still_running' (which means SDB still has
      % writer), because `follow_stream()' didn't set the monitor, so there's
      % no SDB writer
      Result = harp_sdb:result(Handle),
      {terminated, Handle, Since, Result}
  end.

%% }}}
%%----------------------------------------------------------
%% execute_read_stream() {{{

%% @doc Prepare a {@link gen_server} module and its state for reading job's
%%   stream result.

-spec execute_read_stream(harpcaller:job_id(), [{atom(), term()}]) ->
  {ok, Handle :: harp_sdb:handle(), Since :: non_neg_integer()}.

execute_read_stream(JobID, Opts) ->
  harpcaller_log:append_context([{job, {str, JobID}}, {wait, false}]),
  harpcaller_log:info("returning job's result"),
  {ok, Handle} = harp_sdb:load(JobID), % TODO: handle errors
  case Opts of
    [{since, Since}] ->
      ok;
    [{recent, N}] ->
      Since = max(0, harp_sdb:stream_size(Handle) - N)
  end,
  {ok, Handle, Since}.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% helper functions
%%%---------------------------------------------------------------------------

%% @doc Encode a structure and send it as a response to client.

-spec send_response(gen_tcp:socket(), harp_json:jhash()) ->
  ok | {error, inet:posix()}.

send_response(Socket, Response) ->
  {ok, Line} = harp_json:encode(Response),
  gen_tcp:send(Socket, [Line, $\n]).

%% @doc Read stream result from SDB handle and send it to TCP client.
%%
%%   Function returns the next stream record ID to be sent to client (the
%%   first one that wasn't present in the SDB file).

-spec read_and_send_stream_since(harp_sdb:handle(), non_neg_integer(),
                                 gen_tcp:socket()) ->
  non_neg_integer().

read_and_send_stream_since(Handle, Seq, Socket) ->
  case harp_sdb:stream(Handle, Seq) of
    {ok, Rec} ->
      % TODO: handle errors
      ok = send_response(Socket, [{<<"packet">>, Seq}, {<<"data">>, Rec}]),
      read_and_send_stream_since(Handle, Seq + 1, Socket);
    still_running ->
      Seq;
    end_of_stream ->
      Seq
  end.

%% @doc Format result for sending to TCP client.

format_result({return, Value} = _Result) ->
  [{<<"result">>, Value}];

%format_result(still_running = _Result) ->
%  ...; % this should never happen

format_result(cancelled = _Result) ->
  [{<<"cancelled">>, true}];

format_result(missing = _Result) ->
  format_result({error, {<<"missing_result">>,
                          <<"job interrupted abruptly">>}});

format_result({exception, {Type, Message}} = _Result) ->
  [{<<"exception">>,
    [{<<"type">>, Type}, {<<"message">>, Message}]}];
format_result({exception, {Type, Message, Data}} = _Result) ->
  [{<<"exception">>,
    [{<<"type">>, Type}, {<<"message">>, Message}, {<<"data">>, Data}]}];

format_result({error, {Type, Message}} = _Result)
when is_binary(Type), is_binary(Message) ->
  [{<<"error">>,
    [{<<"type">>, Type}, {<<"message">>, Message}]}];
format_result({error, {Type, Message, Data}} = _Result)
when is_binary(Type), is_binary(Message) ->
  [{<<"error">>,
    [{<<"type">>, Type}, {<<"message">>, Message}, {<<"data">>, Data}]}];
format_result({error, Reason} = _Result) ->
  Type = iolist_to_binary(harpcaller_caller:error_type(Reason)),
  Message = iolist_to_binary(harpcaller_caller:format_error(Reason)),
  [{<<"error">>, [{<<"type">>, Type}, {<<"message">>, Message}]}];

format_result(undefined = _Result) ->
  % no such job
  format_result({error, {<<"invalid_jobid">>, <<"no job with this ID">>}}).

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
