%%%---------------------------------------------------------------------------
%%% @doc
%%%   TCP worker that gets from {@link korrpcdid_caller} a streamed response.
%%%   This module takes the process over from {@link korrpcdid_tcp_worker}
%%%   (using {@link gen_server:enter_loop/5}).
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_tcp_return_stream).

-behaviour(gen_server).

%% supervision tree API
-export([state/4]).

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
  mode :: follow | read,
  since  :: non_neg_integer() | undefined,
  recent :: non_neg_integer() | undefined
}).

%%% }}}
%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @doc Create state for use with {@link gen_server:enter_loop/5}.

-spec state(gen_tcp:socket(), korrpcdid:job_id(), follow | read,
            {since, non_neg_integer()} | {recent, non_neg_integer()}) ->
  #state{}.

state(Client, JobID, Mode, {since, S} = _Context)
when Mode == follow; Mode == read ->
  _State = #state{
    client = Client,
    job_id = JobID,
    mode = Mode,
    since = S
  };
state(Client, JobID, Mode, {recent, R} = _Context)
when Mode == follow; Mode == read ->
  _State = #state{
    client = Client,
    job_id = JobID,
    mode = Mode,
    recent = R
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

handle_info({record, JobID, Id, Record} = _Message,
            State = #state{job_id = JobID}) ->
  case send_response(State, [{<<"packet">>, Id}, {<<"data">>, Record}]) of
    ok -> {noreply, State};
    {error, closed} -> {stop, normal, State};
    {error, Reason} -> {stop, Reason, State}
  end;

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
            State = #state{job_id = JobID, client = Client}) ->
  {ok, {_PeerAddr, _PeerPort} = Peer} = inet:peername(Client),
  case State of
    #state{mode = follow, recent = 0} ->
      % special case when there's no need to read the history of stream
      case korrpcdid_caller:follow_stream(JobID) of
        ok ->
          korrpcdid_log:info(?LOG_CAT, "job still running, reading the stream result",
                             [{client, {term, Peer}}, {job, {str, JobID}},
                              {wait, true}]),
          {noreply, State};
        undefined ->
          Result = korrpcdid_caller:get_result(JobID),
          FormattedResult = format_result(Result),
          korrpcdid_log:info(?LOG_CAT, "job is already finished, returning result",
                             [{client, {term, Peer}}, {job, {str, JobID}},
                              {result, FormattedResult}, {wait, true}]),
          send_response(State, FormattedResult),
          {stop, normal, State}
      end;
    #state{mode = follow} ->
      Follow = korrpcdid_caller:follow_stream(JobID),
      case read_stream(State) of
        {ok, NextId} ->
          case Follow of
            ok ->
              % TODO: if this operation specified an ID in the future, skip
              % those as well (probably in `handle_info({record, ...})')
              korrpcdid_log:info(?LOG_CAT, "job still running, reading the stream result",
                                 [{client, {term, Peer}},
                                  {job, {str, JobID}}, {wait, true}]),
              flush_stream(JobID, NextId),
              {noreply, State};
            undefined ->
              Result = korrpcdid_caller:get_result(JobID),
              FormattedResult = format_result(Result),
              korrpcdid_log:info(?LOG_CAT, "job is already finished, returning result",
                                 [{client, {term, Peer}}, {job, {str, JobID}},
                                  {result, FormattedResult}, {wait, true}]),
              send_response(State, FormattedResult),
              {stop, normal, State}
          end;
        {error, Reason} ->
          FormattedResult = format_result({error, Reason}),
          korrpcdid_log:warn(?LOG_CAT, "reading job's recorded data failed",
                             [{client, {term, Peer}}, {job, {str, JobID}},
                              {reason, {term, Reason}}]),
          send_response(State, FormattedResult),
          {stop, Reason, State}
      end;
    #state{mode = read} ->
      read_stream(State), % don't care if successful or not
      Result = korrpcdid_caller:get_result(JobID),
      FormattedResult = format_result(Result),
      korrpcdid_log:info(?LOG_CAT, "returning job's result",
                         [{client, {term, Peer}}, {job, {str, JobID}},
                          {result, FormattedResult}, {wait, false}]),
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

%% @doc Skip messages with records that were already read from {@link
%%   korrpc_sdb}.

-spec flush_stream(korrpcdid:job_id(), non_neg_integer()) ->
  ok.

flush_stream(JobID, Until) ->
  receive
    {record, JobID, Id, _Record} when Id < Until ->
      flush_stream(JobID, Until)
  after 0 ->
      ok
  end.

%% @doc Read streamed messages from {@link korrpc_sdb} and send them to TCP
%%   client.
%%
%%   Function returns `ok'-tuple with record ID to skip until, suitable for
%%   use with {@link flush_stream/2}.
%%
%% @see read_stream/3

-spec read_stream(#state{}) ->
  {ok, NextId :: non_neg_integer()} | {error, term()}.

read_stream(State = #state{job_id = JobID}) ->
  case korrpc_sdb:load(JobID) of
    {ok, DBH} ->
      Result = case State of
        #state{since = undefined, recent = R} when is_integer(R) ->
          case (korrpc_sdb:stream_size(DBH) - R) of
            LastId when LastId >= 0 ->
              % FIXME: read_stream() may send more records than requested if
              % something comes between reading stream size and reading last
              % message (race condition thingy); this is not an important bug,
              % though
              Id = read_stream(State, DBH, LastId),
              {ok, Id};
            _ ->
              {ok, 0}
          end;
        #state{recent = undefined, since = S} when is_integer(S) ->
          Id = read_stream(State, DBH, S),
          {ok, Id}
      end,
      korrpc_sdb:close(DBH),
      Result;
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Read streamed messages from {@link korrpc_sdb} and send them to TCP
%%   client.
%%
%%   Worker function for {@link read_stream/1}.

-spec read_stream(#state{}, korrpc_sdb:handle(), non_neg_integer()) ->
  non_neg_integer().

read_stream(State, DBH, Id) ->
  case korrpc_sdb:stream(DBH, Id) of
    {ok, Record} ->
      send_response(State, [{<<"packet">>, Id}, {<<"data">>, Record}]),
      read_stream(State, DBH, Id + 1);
    still_running ->
      Id;
    end_of_stream ->
      Id
  end.

%%%---------------------------------------------------------------------------

format_result({return, Value} = _Result) ->
  [{<<"result">>, Value}];
format_result(still_running = _Result) ->
  [{<<"continue">>, true}]; % XXX: different from korrpcdid_tcp_return_result
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
format_result({error, Reason} = _Result) when is_atom(Reason) ->
  [{<<"error">>, [
    {<<"type">>, atom_to_binary(Reason, utf8)},
    {<<"message">>, inet:format_error(Reason)}
  ]}];
format_result({error, Reason} = _Result) ->
  [{<<"error">>, [
    {<<"type">>, <<"unrecognized">>},
    % hopefully 1024 chars will be enough; if not, pity, it's still serialized
    % to JSON
    {<<"message">>, iolist_to_binary(iolib:format("~1024p", [Reason]))}
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
