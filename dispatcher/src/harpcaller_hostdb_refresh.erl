%%%---------------------------------------------------------------------------
%%% @doc
%%%   Process to execute a script to retrieve known hosts in regular
%%%   intervals.
%%%   After that the process sends collected data to
%%%   {@link harpcaller_hostdb}.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_hostdb_refresh).

-behaviour(gen_server).

%% public interface
-export([refresh/0]).

%% supervision tree API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------

-define(MAX_LINE, 4096).
-define(LOG_CAT, hostdb_refresh).

-record(state, {
  command :: string(),
  interval :: pos_integer(), % seconds
  port :: port(),
  result :: dict()
}).

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Force refreshing list of hosts.
%%   Does nothing if refreshing is already running.

-spec refresh() ->
  ok.

refresh() ->
  gen_server:cast(?MODULE, refresh_now).

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start example process.

start() ->
  gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @private
%% @doc Start example process.

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init(_Args) ->
  {ok, RefreshCommand} = application:get_env(host_db_script),
  {ok, RefreshInterval} = application:get_env(host_db_refresh),
  State = #state{
    command = RefreshCommand,
    interval = RefreshInterval,
    result = dict:new()
  },
  % it's up to harpcaller_hostdb to decide that hosts database needs immediate
  % refreshing (harpcaller_hostdb can read host_db_refresh on its own)
  erlang:send_after(RefreshInterval * 1000, self(), refresh),
  {ok, State}.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{port = Port}) when is_port(Port) ->
  port_close(Port),
  ok;
terminate(_Arg, _State) ->
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

handle_cast(refresh_now = _Request, State) ->
  harpcaller_log:info(?LOG_CAT, "refresh request outside the schedule", []),
  % execute the command or no-op if a command is already running
  Port = execute(State),
  NewState = State#state{port = Port},
  {noreply, NewState};

%% unknown casts
handle_cast(_Request, State) ->
  {noreply, State}.

%% @private
%% @doc Handle incoming messages.

handle_info({Port, {data, {eol, Line}} = _Data} = _Message,
            State = #state{port = Port, result = Result}) when is_port(Port) ->
  % XXX: this construct ignores lines that are too long (> ?MAX_LINE) and
  % a single line at EOF that wasn't terminated with EOL (if any)
  NewResult = case decode_host_entry(Line) of
    {Name, _Addr, _PortNum, _Creds} = Entry -> dict:store(Name, Entry, Result);
    ignore -> Result
  end,
  NewState = State#state{result = NewResult},
  {noreply, NewState};

handle_info({Port, {exit_status, ExitStatus}} = _Message,
            State = #state{port = Port, result = Result}) when is_port(Port) ->
  %port_close(Port), % don't call this one on exit_status
  case ExitStatus of
    0 ->
      % send the update
      harpcaller_log:info(?LOG_CAT, "refresh script terminated",
                          [{exit_code, ExitStatus}]),
      Entries = dict:fold(
        fun(_Name, Entry, Acc) -> [Entry | Acc] end,
        [],
        Result
      ),
      harpcaller_hostdb ! {fill, Entries};
    _ ->
      % only use successful runs, otherwise the script could have died of some
      % unexpected reason and it would clear the known hosts registry
      harpcaller_log:warn(?LOG_CAT, "refresh script terminated abnormally",
                          [{exit_code, ExitStatus}]),
      ignore
  end,
  NewState = State#state{
    port = undefined,
    result = dict:new()
  },
  {noreply, NewState};

handle_info(refresh = _Message, State = #state{interval = RefreshInterval}) ->
  % schedule the next refresh
  harpcaller_log:info(?LOG_CAT, "refreshing on schedule",
                      [{schedule, RefreshInterval}]),
  erlang:send_after(RefreshInterval * 1000, self(), refresh),
  % execute the command or no-op if a command is already running
  Port = execute(State),
  NewState = State#state{port = Port},
  {noreply, NewState};

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

%% @doc Ensure the command is running as a port.
%%   If it is not running, spawn a new port. If it is, just return its handle.

-spec execute(#state{}) ->
  port().

execute(_State = #state{port = undefined, command = Command}) ->
  harpcaller_log:info(?LOG_CAT, "starting refresh script",
                      [{command, {str, Command}}]),
  open_port({spawn_executable, Command}, [{line, ?MAX_LINE}, in, exit_status]);
execute(_State = #state{port = Port}) when is_port(Port) ->
  harpcaller_log:info(?LOG_CAT, "refresh script is already running", []),
  Port.

%% @doc Decode a JSON line to host entry

-spec decode_host_entry(string() | binary()) ->
  harpcaller_hostdb:host_entry() | ignore.

decode_host_entry(String) ->
  try
    {ok, Data} = harp_json:decode(String),
    Name = orddict:fetch(<<"hostname">>, Data),
    % TODO: detect IPv4/IPv6 addresses
    Address = binary_to_list(orddict:fetch(<<"address">>, Data)),
    Port = orddict:fetch(<<"port">>, Data),
    [{<<"password">>, Password}, {<<"user">>, User}] =
      orddict:fetch(<<"credentials">>, Data),
    {Name, Address, Port, {User, Password}}
  catch
    error:_ ->
      % not a valid JSON, not a JSON hash, or one of the mandatory fields is
      % missing or invalid
      ignore
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
