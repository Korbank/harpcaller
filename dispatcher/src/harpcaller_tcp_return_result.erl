%%%---------------------------------------------------------------------------
%%% @doc
%%%   TCP worker that gets from {@link harpcaller_caller} a call result.
%%%   This module takes the process over from {@link harpcaller_tcp_worker}
%%%   (using {@link gen_server:enter_loop/5}).
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_tcp_return_result).

-behaviour(gen_server).

%% supervision tree API
-export([state/3]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-record(state, {
  client :: gen_tcp:socket(),
  job_id :: harpcaller:job_id(),
  job_monitor :: reference(),
  wait :: boolean()
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @doc Create state for use with {@link gen_server:enter_loop/5}.

-spec state(gen_tcp:socket(), harpcaller:job_id(), boolean()) ->
  #state{}.

state(Client, JobID, Wait) when Wait == true; Wait == false ->
  _State = #state{
    client = Client,
    job_id = JobID,
    wait = Wait
  }.

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init([] = _Args) ->
  % XXX: this will never be called
  % NOTE: if ever called, remember to add `harpcaller_log:set_context()'
  State = #state{},
  {ok, State}.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{client = Socket}) ->
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

handle_info({record, JobID, _Id, _Record} = _Message,
            State = #state{job_id = JobID}) ->
  % streamed response -- ignore this message
  {noreply, State};

handle_info({'DOWN', Monitor, process, Pid, Reason} = _Message,
            State = #state{job_monitor = Monitor}) ->
  % the process carrying out the job died
  harpcaller_log:info("job died",
                      [{pid, {term, Pid}}, {reason, {term, Reason}}]),
  send_response(State, format_result(missing)),
  {stop, normal, State};

handle_info({terminated, JobID, Result} = _Message,
            State = #state{job_id = JobID}) ->
  % got our result; send it to the client
  harpcaller_log:info("job terminated"),
  send_response(State, format_result(Result)),
  {stop, normal, State};

handle_info(timeout = _Message,
            State = #state{job_id = JobID, wait = false}) ->
  harpcaller_log:append_context([{wait, false}]),
  Value = harpcaller_caller:get_result(JobID),
  harpcaller_log:info("returning job's result"),
  send_response(State, format_result(Value)),
  {stop, normal, State};

handle_info(timeout = _Message,
            State = #state{job_id = JobID, wait = true}) ->
  harpcaller_log:append_context([{wait, true}]),
  case harpcaller_caller:follow_stream(JobID) of
    {ok, MonRef} ->
      % consume+ignore all the stream, waiting for the result
      harpcaller_log:info("job still running, waiting for the result"),
      NewState = State#state{job_monitor = MonRef},
      {noreply, NewState};
    undefined ->
      % no process to follow, so it must terminated already
      Value = harpcaller_caller:get_result(JobID),
      harpcaller_log:info("returning job's result"),
      send_response(State, format_result(Value)),
      {stop, normal, State}
  end;

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

format_result({return, Value} = _Result) ->
  [{<<"result">>, Value}];
format_result(still_running = _Result) ->
  [{<<"no_result">>, true}]; % XXX: different from harpcaller_tcp_return_stream
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
format_result({error, unknown_host} = _Result) ->
  [{<<"error">>, [
    {<<"type">>, <<"unknown_host">>},
    {<<"message">>, <<"host unknown">>}
  ]}];
format_result({error, timeout} = _Result) ->
  [{<<"error">>, [
    {<<"type">>, <<"timeout">>},
    {<<"message">>, <<"request timed out">>}
  ]}];
format_result({error, closed} = _Result) ->
  [{<<"error">>, [
    {<<"type">>, <<"closed">>},
    {<<"message">>, <<"connection closed unexpectedly">>}
  ]}];
format_result({error, {ssl, Reason}} = _Result) ->
  [{<<"error">>, [
    {<<"type">>, <<"ssl">>},
    {<<"message">>, list_to_binary(ssl:format_error(Reason))}
  ]}];
format_result({error, Reason} = _Result) when is_atom(Reason) ->
  [{<<"error">>, [
    {<<"type">>, atom_to_binary(Reason, utf8)},
    {<<"message">>, list_to_binary(inet:format_error(Reason))}
  ]}];
format_result({error, Reason} = _Result) ->
  % XXX: this can be an error coming from `ssl' application, like certificate
  % verification error
  [{<<"error">>, [
    {<<"type">>, <<"unrecognized">>},
    % hopefully 1024 chars will be enough; if not, pity, it's still serialized
    % to JSON
    {<<"message">>, iolist_to_binary(io_lib:format("~1024p", [Reason]))}
  ]}];
format_result(undefined = _Result) ->
  % no such job
  format_result({error, {<<"invalid_jobid">>, <<"no job with this ID">>}}).

%%----------------------------------------------------------

%% @doc Encode a structure and send it as a response to client.

-spec send_response(#state{}, harp_json:jhash()) ->
  ok | {error, term()}.

send_response(_State = #state{client = Socket}, Response) ->
  {ok, Line} = harp_json:encode(Response),
  gen_tcp:send(Socket, [Line, $\n]).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
