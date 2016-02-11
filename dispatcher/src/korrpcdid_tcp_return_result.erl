%%%---------------------------------------------------------------------------
%%% @doc
%%%   TCP worker that gets from {@link korrpcdid_caller} a call result.
%%%   This module takes the process over from {@link korrpcdid_tcp_worker}
%%%   (using {@link gen_server:enter_loop/5}).
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_tcp_return_result).

-behaviour(gen_server).

%% supervision tree API
-export([state/3]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% types {{{

-define(LOG_CAT, connection).

-record(state, {
  client :: gen_tcp:socket(),
  job_id :: korrpcdid:job_id(),
  wait :: boolean()
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @doc Create state for use with {@link gen_server:enter_loop/5}.

-spec state(gen_tcp:socket(), korrpcdid:job_id(), boolean()) ->
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
handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

%% unknown casts
handle_cast(_Request, State) ->
  {noreply, State}.

%% @private
%% @doc Handle incoming messages.

handle_info({record, JobID, _Id, _Record} = _Message,
            State = #state{job_id = JobID}) ->
  % streamed response -- ignore this message
  {noreply, State};

handle_info({terminated, JobID, Result} = _Message,
            State = #state{job_id = JobID, client = Client}) ->
  % got our result; send it to the client
  FormattedResult = format_result(Result),
  {ok, {_PeerAddr, _PeerPort} = Peer} = inet:peername(Client),
  korrpcdid_log:info(?LOG_CAT, "job terminated",
                     [{client, {term, Peer}}, {job, {str, JobID}},
                      {result, FormattedResult}, {wait, true}]),
  send_response(State, FormattedResult),
  {stop, normal, State};

handle_info(timeout = _Message,
            State = #state{job_id = JobID, client = Client, wait = false}) ->
  Value = korrpcdid_caller:get_result(JobID),
  FormattedResult = format_result(Value),
  {ok, {_PeerAddr, _PeerPort} = Peer} = inet:peername(Client),
  korrpcdid_log:info(?LOG_CAT, "returning job's result",
                     [{client, {term, Peer}}, {job, {str, JobID}},
                      {result, FormattedResult}, {wait, false}]),
  send_response(State, FormattedResult),
  {stop, normal, State};

handle_info(timeout = _Message,
            State = #state{job_id = JobID, client = Client, wait = true}) ->
  {ok, {_PeerAddr, _PeerPort} = Peer} = inet:peername(Client),
  case korrpcdid_caller:follow_stream(JobID) of
    ok ->
      % consume+ignore all the stream, waiting for the result
      korrpcdid_log:info(?LOG_CAT, "job still running, waiting for the result",
                         [{client, {term, Peer}}, {job, {str, JobID}},
                          {wait, true}]),
      {noreply, State};
    undefined ->
      % no process to follow, so it must terminated already
      Value = korrpcdid_caller:get_result(JobID),
      FormattedResult = format_result(Value),
      {ok, {_PeerAddr, _PeerPort} = Peer} = inet:peername(Client),
      korrpcdid_log:info(?LOG_CAT, "returning job's result",
                         [{client, {term, Peer}}, {job, {str, JobID}},
                          {result, FormattedResult}, {wait, true}]),
      send_response(State, FormattedResult),
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

format_result({return, Value} = _Result) ->
  [{<<"result">>, Value}];
format_result(still_running = _Result) ->
  [{<<"no_result">>, true}]; % XXX: different from korrpcdid_tcp_return_stream
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
format_result({error, closed} = _Result) ->
  [{<<"error">>, [
    {<<"type">>, <<"closed">>},
    {<<"message">>, <<"connection closed unexpectedly">>}
  ]}];
format_result({error, esslconnect} = _Result) ->
  [{<<"error">>, [
    {<<"type">>, <<"esslconnect">>},
    {<<"message">>, <<"server certificate verification failed">>}
  ]}];
format_result({error, Reason} = _Result) when is_atom(Reason) ->
  [{<<"error">>, [
    {<<"type">>, atom_to_binary(Reason, utf8)},
    {<<"message">>, list_to_binary(inet:format_error(Reason))}
  ]}];
format_result({error, Reason} = _Result) ->
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

-spec send_response(#state{}, korrpc_json:jhash()) ->
  ok | {error, term()}.

send_response(_State = #state{client = Socket}, Response) ->
  {ok, Line} = korrpc_json:encode(Response),
  gen_tcp:send(Socket, [Line, $\n]).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
