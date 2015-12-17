%%%----------------------------------------------------------------------------
%%% @doc
%%%   Stream result database reading/writing.
%%%
%%% @todo Load table from disk
%%% @end
%%%----------------------------------------------------------------------------

-module(korrpc_sdb).

-behaviour(gen_server).

%% supervision tree API
-export([start/5, start_link/5]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%% public interface
-export([new/4, load/1, close/1]).
-export([insert/2, set_result/2]).
-export([result/1, stream/2, stream_size/1]).

-export_type([handle/0]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-record(state, {
  table_name,
  data :: ets:tab(), % in future: dets:tab_name()
  stream_counter = 0,
  finished :: boolean(),
  owner :: {pid(), reference()}
}).

-type handle() :: pid().
%% Result table handle.

-type table_name() :: string().
%% UUID string representation.

-include("korrpc_sdb.hrl").

% }}}
%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% opening/closing tables {{{

%% @doc Create new, empty table.

-spec new(table_name(), korrpc:procedure(), [korrpc:argument()],
          {inet:hostname() | inet:ip_address(), inet:port_number()}) ->
  {ok, handle()} | {error, term()}.

new(TableName, Procedure, ProcArgs, RemoteAddress) ->
  Args = [TableName, Procedure, ProcArgs, RemoteAddress, self()],
  {ok, Pid} = korrpc_sdb_sup:spawn_child(Args),
  {ok, Pid}.

%% @doc Load an existing table.

-spec load(table_name()) ->
  {ok, handle()} | {error, term()}.

load(TableName) ->
  case ets:lookup(?ETS_REGISTRY_TABLE, TableName) of
    [{TableName, Pid}] -> {ok, Pid};
    [] -> {error, enoent}
  end.

%% @doc Close table handle.

-spec close(handle()) ->
  ok.

close(Handle) ->
  gen_server:call(Handle, close).

%% }}}
%%----------------------------------------------------------
%% storing data that came from RPC call {{{

%% @doc Insert one record from stream from RPC call.

-spec insert(handle(), korrpc:stream_record()) ->
  ok.

insert(Handle, Record) ->
  gen_server:call(Handle, {add_stream, Record}).

%% @doc Set result from RPC call.
%%   It can be later retrieved by calling {@link result/1}.

-spec set_result(handle(), {return, korrpc:result()}
                 | {exception, korrpc:error_description()}
                 | {error, korrpc:error_description() | term()}
                 | cancelled) ->
  ok.

%% filter invalid data
set_result(Handle, {return,_} = Result) ->
  gen_server:call(Handle, {set_result, Result});
set_result(Handle, {exception,_} = Result) ->
  gen_server:call(Handle, {set_result, Result});
set_result(Handle, {error,_} = Result) ->
  gen_server:call(Handle, {set_result, Result});
set_result(Handle, cancelled = Result) ->
  gen_server:call(Handle, {set_result, Result}).

%% }}}
%%----------------------------------------------------------
%% retrieving data that came from RPC call {{{

%% @doc Get recorded RPC call result.
%%   If the result was not stored yet ({@link set_result/2}), the job is
%%   considered to be running and `still_running' is returned.
%%
%%   If the table was read from disk and no result was stored previously,
%%   `missing' is returned.

-spec result(handle()) ->
    {return, korrpc:result()}
  | still_running
  | cancelled
  | missing
  | {exception, korrpc:error_description()}
  | {error, korrpc:error_description() | term()}.

result(Handle) ->
  gen_server:call(Handle, get_result).

%% @doc Get next streamed message.
%%   If there are no more records stored, `end_of_stream' or `still_running'
%%   is returned. The former indicates that the job terminated, while the
%%   latter tells that in future there may be some more records to read (if
%%   the job produces them, of course).

-spec stream(handle(), non_neg_integer()) ->
  {ok, korrpc:stream_record()} | still_running | end_of_stream.

stream(Handle, Seq) when is_integer(Seq), Seq >= 0 ->
  gen_server:call(Handle, {get_stream, Seq}).

%% @doc Get current size of stream (number of collected records so far).

-spec stream_size(handle()) ->
  non_neg_integer().

stream_size(Handle) ->
  gen_server:call(Handle, get_stream_size).

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start stream DB process.

start(TableName, Procedure, ProcArgs, RemoteAddress, Owner) ->
  Args = [TableName, Procedure, ProcArgs, RemoteAddress, Owner],
  gen_server:start(?MODULE, Args, []).

%% @private
%% @doc Start stream DB process.

start_link(TableName, Procedure, ProcArgs, RemoteAddress, Owner) ->
  Args = [TableName, Procedure, ProcArgs, RemoteAddress, Owner],
  gen_server:start_link(?MODULE, Args, []).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init([TableName, _Procedure, _ProcArgs, _RemoteAddress, Owner] = _Args) ->
  link(Owner),
  MonRef = monitor(process, Owner),
  StreamTable = ets:new(stream_data, [ordered_set]),
  ets:insert(StreamTable, {stream_count, 0}),
  State = #state{
    table_name = TableName,
    data = StreamTable,
    finished = false,
    owner = {Owner, MonRef}
  },
  ets:insert(?ETS_REGISTRY_TABLE, {TableName, self()}),
  {ok, State}.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{data = StreamTable, table_name = TableName}) ->
  ets:delete(StreamTable),
  ets:delete(?ETS_REGISTRY_TABLE, TableName),
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

%% add record streamed by RPC call
handle_call({add_stream, Record} = _Request, _From,
            State = #state{data = StreamTable, stream_counter = N}) ->
  case State of
    #state{finished = true} ->
      NewState = State; % ignore if finished
    #state{finished = false} ->
      ets:insert(StreamTable, {N, Record}),
      ets:update_counter(StreamTable, stream_count, 1),
      NewState = State#state{stream_counter = N + 1}
  end,
  {reply, ok, NewState};

%% add record streamed by RPC call
handle_call({set_result, Result} = _Request, _From,
            State = #state{data = StreamTable}) ->
  % Result :: {return, term()} | cancelled |
  %            {exception, term()} | {error, term()}
  ets:insert(StreamTable, {result, Result}),
  NewState = State#state{finished = true},
  {reply, ok, NewState};

%% get result returned by RPC call, if any
handle_call(get_result = _Request, _From, State = #state{finished = false}) ->
  {reply, still_running, State};
handle_call(get_result = _Request, _From, State = #state{data = StreamTable}) ->
  Result = case ets:lookup(StreamTable, result) of
    [] -> missing;
    [{result, {return, R}}]    -> {return, R};
    [{result, {exception, E}}] -> {exception, E};
    [{result, {error, E}}]     -> {error, E};
    [{result, cancelled}] -> cancelled
  end,
  {reply, Result, State};

%% get a record from stream produced by RPC call
handle_call({get_stream, Seq} = _Request, _From,
            State = #state{data = StreamTable, stream_counter = N}) ->
  Result = case State of
    #state{finished = true} when Seq >= N ->
      end_of_stream;
    #state{finished = false} when Seq >= N ->
      still_running;
    _ when Seq < N ->
      [{Seq, Record}] = ets:lookup(StreamTable, Seq),
      {ok, Record}
  end,
  {reply, Result, State};

%% get the number of collected records so far
handle_call(get_stream_size = _Request, _From,
            State = #state{data = StreamTable}) ->
  [{stream_count, Count}] = ets:lookup(StreamTable, stream_count),
  {reply, Count, State};

%% close the handle
handle_call(close = _Request, _From, State) ->
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

%% owner shut down
handle_info({'DOWN', MonRef, process, Pid, _} = _Message,
            State = #state{owner = {Pid, MonRef}}) ->
  {stop, normal, State};

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
