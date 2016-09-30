%%%----------------------------------------------------------------------------
%%% @doc
%%%   Stream result database reading/writing.
%%%
%%%   <h2><a name="sdb-content">Database Files</a></h2>
%%%
%%%   Database files written by this module are {@link dets} files that store
%%%   several records, some of them optional.
%%%
%%%   <ul>
%%%     <li>{@type @{procedure, @{harp:procedure(), [harp:argument()]@}@}}
%%%         -- always stored</li>
%%%     <li>{@type @{host, address()@}} -- always stored</li>
%%%     <li>{@type @{job_submitted, Epoch :: integer()@}} -- always
%%%         stored</li>
%%%     <li>{@type @{job_start, Epoch :: integer()@}} -- for jobs that were
%%%         started (released from waiting in a queue)</li>
%%%     <li>{@type @{job_end, Epoch :: integer()@}} -- for jobs that ended (in
%%%         whatever manner), this record will be present; it will be missing
%%%         if the job is still running (obviously) or if HarpCaller was
%%%         stopped without opportunity to write anything to disk (e.g. on
%%%         hard reboot)</li>
%%%     <li>{@type @{stream_count, C :: non_neg_integer()@}} -- record telling
%%%         how many stream records the job produced; always stored with
%%%         `C = 0' and later updated as stream records arrive</li>
%%%     <li>{@type @{N :: non_neg_integer(), Record :: harp:stream_record()@}}
%%%         -- records streamed by the job; `N' starts with 0 and the largest
%%%         in database is equal to `C - 1'</li>
%%%     <li>{@type @{result, @{return, harp:result()@}@}} -- call ended
%%%         successfully; stored along with `{job_end, Epoch}'</li>
%%%     <li>{@type @{result, cancelled@}} -- call was cancelled; stored along
%%%         with `{job_end, Epoch}'</li>
%%%     <li>{@type @{result, @{exception, harp:error_description()@}@}} --
%%%         call ended with an exception raised in the remote procedure;
%%%         stored along with `{job_end, Epoch}'</li>
%%%     <li>{@type @{result, @{error, harp:error_description() | term()@}@}}
%%%         -- call encountered an error; stored along with `{job_end,
%%%         Epoch}'</li>
%%%   </ul>
%%% @end
%%%----------------------------------------------------------------------------

-module(harp_sdb).

-behaviour(gen_server).

%% supervision tree API
-export([start/6, start/3, start_link/6, start_link/3]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%% public interface
-export([new/4, load/1, close/1]).
-export([started/1, insert/2, set_result/2]).
-export([result/1, stream/2, stream_size/1, info/1]).
-export([remove_older/1]).

-export_type([handle/0, info_call/0, info_time/0]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-record(state, {
  table_name,
  data :: dets:tab_name(),
  stream_counter = 0,
  finished :: boolean(),
  holders :: ets:tab()
}).

-type handle() :: pid().
%% Result table handle.

-type table_name() :: string().
%% UUID string representation.

-define(TABLE_NAME_RE, "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$").

-type address() :: term().

-type epoch() :: integer().

-type info_call() :: {harp:procedure(), [harp:argument()]}.
-type info_time() ::
  {Submitted :: epoch(),
    Started :: epoch() | undefined,
    Ended :: epoch() | undefined}.

-include("harp_sdb.hrl").

%%% }}}
%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% opening/closing tables {{{

%% @doc Create new, empty table.

-spec new(table_name(), harp:procedure(), [harp:argument()], address()) ->
  {ok, handle()} | {error, term()}.

new(TableName, Procedure, ProcArgs, RemoteAddress) ->
  Args = [TableName, self(), write, Procedure, ProcArgs, RemoteAddress],
  case harp_sdb_sup:spawn_child(Args) of
    {ok, Pid} when is_pid(Pid) -> {ok, Pid};
    {ok, undefined} -> {error, eexist};
    {error, Reason} -> {error, Reason}
  end.

%% @doc Load an existing table.

-spec load(table_name()) ->
  {ok, handle()} | {error, term()}.

load(TableName) ->
  case try_load(TableName) of
    {ok, Pid} ->
      {ok, Pid};
    again ->
      case try_load(TableName) of
        {ok, Pid} -> {ok, Pid};
        again -> {error, file_load_race_condition};
        {error, Reason} -> {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Try loading an existing table (workhorse for {@link load/1}).

-spec try_load(table_name()) ->
  {ok, handle()} | again | {error, term()}.

try_load(TableName) ->
  % FIXME: this is a race condition between lookup and call/spawn
  case ets:lookup(?ETS_REGISTRY_TABLE, TableName) of
    [{TableName, Pid}] ->
      try
        ok = gen_server:call(Pid, {load, self()}),
        {ok, Pid}
      catch
        exit:{noproc,_} -> again;
        exit:{normal,_} -> again
      end;
    [] ->
      case harp_sdb_sup:spawn_child([TableName, self(), read]) of
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        {ok, undefined} -> again;
        {error, Reason} -> {error, Reason}
      end
  end.

%% @doc Close table handle.

-spec close(handle()) ->
  ok.

close(Handle) ->
  % FIXME: this single call makes it impossible to keep several handles to the
  % same table in a single process (though it should not be a problem ATM)
  gen_server:call(Handle, {close, self()}).

%% }}}
%%----------------------------------------------------------
%% storing data that came from RPC call {{{

%% @doc Mark the start of RPC call.
%%
%%   This is an important distinction, when the call was ordered and when it
%%   actually started. This was introduced because of queued calls.

-spec started(handle()) ->
  ok.

started(Handle) ->
  gen_server:call(Handle, started).

%% @doc Insert one record from stream from RPC call.

-spec insert(handle(), harp:stream_record()) ->
  ok.

insert(Handle, Record) ->
  gen_server:call(Handle, {add_stream, Record}).

%% @doc Set result from RPC call.
%%   It can be later retrieved by calling {@link result/1}.

-spec set_result(handle(), {return, harp:result()}
                 | {exception, harp:error_description()}
                 | {error, harp:error_description() | term()}
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
    {return, harp:result()}
  | still_running
  | cancelled
  | missing
  | {exception, harp:error_description()}
  | {error, harp:error_description() | term()}.

result(Handle) ->
  gen_server:call(Handle, get_result).

%% @doc Get next streamed message.
%%   If there are no more records stored, `end_of_stream' or `still_running'
%%   is returned. The former indicates that the job terminated, while the
%%   latter tells that in future there may be some more records to read (if
%%   the job produces them, of course).

-spec stream(handle(), non_neg_integer()) ->
  {ok, harp:stream_record()} | still_running | end_of_stream.

stream(Handle, Seq) when is_integer(Seq), Seq >= 0 ->
  gen_server:call(Handle, {get_stream, Seq}).

%% @doc Get current size of stream (number of collected records so far).

-spec stream_size(handle()) ->
  non_neg_integer().

stream_size(Handle) ->
  gen_server:call(Handle, get_stream_size).

%% @doc Get information recorded about the RPC call.

-spec info(handle()) ->
  {ok, {info_call(), address(), info_time()}}.

info(Handle) ->
  gen_server:call(Handle, get_info).

%% }}}
%%----------------------------------------------------------
%% pruning old tables {{{

%% @doc Remove SDB files older than specified time.
%%
%%   Age of an SDB file is determined from its submission time.
%%
%%   Function doesn't remove SDBs that are still opened. Invalid SDBs are
%%   removed unconditionally.

-spec remove_older(integer()) ->
  ok.

remove_older(Seconds) ->
  {ok, Directory} = application:get_env(harpcaller, stream_directory),
  OlderThan = timestamp() - Seconds,
  FoldFun = fun(F, Acc) ->
    remove_if_older(F, OlderThan),
    Acc
  end,
  filelib:fold_files(Directory, ?TABLE_NAME_RE, false, FoldFun, []),
  ok.

%% @doc Remove stream log if it's submitted earlier than specified timestamp.
%%
%%   If it's an invalid stream log, it's removed as well.
%%
%%   File that is still opened is not removed.

-spec remove_if_older(file:filename(), integer()) ->
  any().

remove_if_older(File, Timestamp) ->
  case is_still_opened(File) of
    false ->
      case submitted_time(File) of
        undefined -> file:delete(File);
        Created when Created =< Timestamp -> file:delete(File);
        _Created -> ok
      end;
    true ->
      skip
  end.

%% @doc Check if the specified file is still opened as SDB.

-spec is_still_opened(file:filename()) ->
  boolean().

is_still_opened(File) ->
  TableName = filename:basename(File),
  case ets:lookup(?ETS_REGISTRY_TABLE, TableName) of
    [{TableName, _Pid}] -> true;
    [] -> false
  end.

%% @doc Read submission time from SDB file.

-spec submitted_time(file:filename()) ->
  integer() | undefined.

submitted_time(File) ->
  case dets:open_file(make_ref(), [{file, File}, {access, read}]) of
    {ok, FH} ->
      Created = case dets:lookup(FH, job_submitted) of
        [{job_submitted, Time}] when is_integer(Time) -> Time;
        _ -> undefined % no record, multiple records, invalid record, error
      end,
      dets:close(FH),
      Created;
    {error, _} ->
      % any read error, including not-a-DETS, enoent, eperm
      undefined
  end.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start R/W stream DB process.

start(TableName, Pid, AccessMode, Procedure, ProcArgs, RemoteAddress) ->
  Args = [TableName, Pid, AccessMode, Procedure, ProcArgs, RemoteAddress],
  gen_server:start(?MODULE, Args, []).

%% @private
%% @doc Start R/O stream DB process.

start(TableName, Pid, AccessMode) ->
  Args = [TableName, Pid, AccessMode],
  gen_server:start(?MODULE, Args, []).

%% @private
%% @doc Start stream DB process.

start_link(TableName, Pid, AccessMode, Procedure, ProcArgs, RemoteAddress) ->
  Args = [TableName, Pid, AccessMode, Procedure, ProcArgs, RemoteAddress],
  gen_server:start_link(?MODULE, Args, []).

%% @private
%% @doc Start R/O stream DB process.

start_link(TableName, Pid, AccessMode) ->
  Args = [TableName, Pid, AccessMode],
  gen_server:start_link(?MODULE, Args, []).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init([TableName, Pid | AccessModeAndArgs] = _Args) ->
  case ets:insert_new(?ETS_REGISTRY_TABLE, {TableName, self()}) of
    true ->
      % TODO: check `TableName' for valid name format
      {ok, Directory} = application:get_env(stream_directory),
      Filename = filename:join(Directory, TableName),
      % prepare monitoring table
      HoldersTable = ets:new(holders, [bag]),
      MonRef = monitor(process, Pid),
      ets:insert(HoldersTable, {Pid, MonRef}),
      % access mode for DETS table (R/O or R/W)
      Access = case AccessModeAndArgs of
        [read] -> read;
        [write, _, _, _] -> read_write
      end,
      case dets:open_file(Filename, [{type, set}, {access, Access}]) of
        {ok, StreamTable} ->
          case AccessModeAndArgs of
            [write, Procedure, ProcArgs, RemoteAddress] ->
              % additional marker when to (pretend to) close the table
              ets:insert(HoldersTable, {rw, Pid}),
              % job metadata
              dets:insert(StreamTable, [
                {procedure, {Procedure, ProcArgs}},
                {host, RemoteAddress},
                {job_submitted, timestamp()},
                {stream_count, 0}
              ]),
              State = #state{
                table_name = TableName,
                stream_counter = 0,
                data = StreamTable,
                holders = HoldersTable,
                finished = false
              },
              {ok, State};
            [read] ->
              [{stream_count, Count}] = dets:lookup(StreamTable, stream_count),
              State = #state{
                table_name = TableName,
                stream_counter = Count,
                data = StreamTable,
                holders = HoldersTable,
                finished = true
              },
              {ok, State}
          end;
        {error, {file_error, _, Reason}} ->
          ets:delete_object(?ETS_REGISTRY_TABLE, {TableName, self()}),
          {stop, Reason};
        {error, Reason} ->
          ets:delete_object(?ETS_REGISTRY_TABLE, {TableName, self()}),
          {stop, Reason}
      end;
    false ->
      ignore
  end.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{data = StreamTable, holders = HoldersTable,
                                table_name = TableName}) ->
  dets:close(StreamTable),
  ets:delete(HoldersTable), % should be empty by now
  ets:delete(?ETS_REGISTRY_TABLE, TableName),
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call(started = _Request, _From, State = #state{data = StreamTable}) ->
  case State of
    #state{finished = true} ->
      ignore;
    #state{finished = false} ->
      dets:insert(StreamTable, {job_start, timestamp()})
  end,
  {reply, ok, State};

%% add record streamed by RPC call
handle_call({add_stream, Record} = _Request, _From,
            State = #state{data = StreamTable, stream_counter = N}) ->
  case State of
    #state{finished = true} ->
      NewState = State; % ignore if finished
    #state{finished = false} ->
      dets:insert(StreamTable, {N, Record}),
      dets:update_counter(StreamTable, stream_count, 1),
      NewState = State#state{stream_counter = N + 1}
  end,
  {reply, ok, NewState};

%% add record streamed by RPC call
handle_call({set_result, Result} = _Request, _From,
            State = #state{data = StreamTable}) ->
  % Result :: {return, term()} | cancelled |
  %            {exception, term()} | {error, term()}
  case State of
    #state{finished = true} ->
      NewState = State; % ignore if finished
    #state{finished = false} ->
      dets:insert(StreamTable, {result, Result}),
      dets:insert(StreamTable, {job_end, timestamp()}),
      NewState = State#state{finished = true}
  end,
  {reply, ok, NewState};

%% get result returned by RPC call, if any
handle_call(get_result = _Request, _From, State = #state{finished = false}) ->
  {reply, still_running, State};
handle_call(get_result = _Request, _From, State = #state{data = StreamTable}) ->
  Result = case dets:lookup(StreamTable, result) of
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
      [{Seq, Record}] = dets:lookup(StreamTable, Seq),
      {ok, Record}
  end,
  {reply, Result, State};

%% get the number of collected records so far
handle_call(get_stream_size = _Request, _From,
            State = #state{stream_counter = Count}) ->
  {reply, Count, State};

%% get some information about RPC call
handle_call(get_info = _Request, _From, State = #state{data = StreamTable}) ->
  [{procedure, {_, _} = CallInfo}] = dets:lookup(StreamTable, procedure),
  [{host, Host}] = dets:lookup(StreamTable, host),
  [{job_submitted, SubmitTime}] = dets:lookup(StreamTable, job_submitted),
  case dets:lookup(StreamTable, job_start) of
    [{job_start, StartTime}] -> ok;
    [] -> StartTime = undefined
  end,
  case dets:lookup(StreamTable, job_end) of
    [{job_end, EndTime}] -> ok;
    [] -> EndTime = undefined
  end,
  TimeInfo = {SubmitTime, StartTime, EndTime},
  Info = {CallInfo, Host, TimeInfo},
  {reply, {ok, Info}, State};

%% open a handle to an already opened database
handle_call({load, Pid} = _Request, _From,
            State = #state{holders = HoldersTable}) ->
  MonRef = monitor(process, Pid),
  ets:insert(HoldersTable, {Pid, MonRef}),
  {reply, ok, State};

%% close the handle
handle_call({close, Pid} = _Request, _From,
            State = #state{holders = HoldersTable}) ->
  [demonitor(Ref, [flush]) || {_, Ref} <- ets:lookup(HoldersTable, Pid)],
  ets:delete(HoldersTable, Pid),
  case ets:lookup(HoldersTable, rw) of
    [{rw, Pid}] ->
      ets:delete(HoldersTable, rw),
      NewState = State#state{finished = true};
    _ ->
      NewState = State
  end,
  case ets:info(HoldersTable, size) of
    0 -> {stop, normal, ok, NewState};
    _ -> {reply, ok, NewState}
  end;

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

%% owner shut down
handle_info({'DOWN', MonRef, process, Pid, _} = _Message,
            State = #state{holders = HoldersTable}) ->
  ets:delete_object(HoldersTable, {Pid, MonRef}),
  case ets:lookup(HoldersTable, rw) of
    [{rw, Pid}] ->
      ets:delete(HoldersTable, rw),
      NewState = State#state{finished = true};
    _ ->
      NewState = State
  end,
  case ets:info(HoldersTable, size) of
    0 -> {stop, normal, NewState};
    _ -> {noreply, NewState}
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

%% @doc Read OS timestamp as unix epoch time.

-spec timestamp() ->
  integer().

timestamp() ->
  {MS, S, _US} = os:timestamp(),
  MS * 1000 * 1000 + S.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
