%%%---------------------------------------------------------------------------
%%% @doc
%%%   Address resolver for known hosts.
%%%   The process also stores credentials and port numbers of the hosts.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_hostdb).

-behaviour(gen_server).

%% public interface
-export([resolve/1, refresh/0, list/0]).
-export([format_address/1]).

%% supervision tree API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

-export_type([host_entry/0]).

-include_lib("stdlib/include/ms_transform.hrl"). %% ets:fun2ms()

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-record(state, {
  table :: dets:tab_name()
}).

-type host_entry() :: {
  Name :: harpcaller:hostname(),
  Address :: harpcaller:address(),
  Port :: inet:port_number(),
  Credentials :: {User :: binary(), Password :: binary()}
}.

%%% }}}
%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Retrieve address, port, and credentials necessary to connect to
%%   specified host.

-spec resolve(harpcaller:hostname()) ->
  harpcaller_hostdb:host_entry() | none.

resolve(Hostname) when is_binary(Hostname) ->
  gen_server:call(?MODULE, {resolve, Hostname}).

%% @doc Force refreshing list of hosts out of regular schedule.

-spec refresh() ->
  ok.

refresh() ->
  harpcaller_hostdb_refresh:refresh().

%% @doc List all known hosts.

-spec list() ->
  [{harpcaller:hostname(), harpcaller:address(), inet:port_number()}].

list() ->
  gen_server:call(?MODULE, list_hosts).

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start host database process.

start() ->
  gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% @private
%% @doc Start host database process.

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
  harpcaller_log:set_context(hostdb, []),
  {ok, TableFile} = application:get_env(host_db),
  {ok, Table} = dets:open_file(TableFile, [{type, set}]),
  State = #state{
    table = Table
  },
  {ok, RefreshInterval} = application:get_env(host_db_refresh),
  {MS,S,_US} = os:timestamp(),
  Timestamp = MS * 1000 * 1000 + S,
  % in case of starting/restarting, wait only half of the usual refresh
  % interval, otherwise it could grow up to almost twice the refresh, and that
  % would be a little too much
  LastUpdateExpected = Timestamp - RefreshInterval div 2,
  case dets:lookup(Table, updated) of
    [] ->
      refresh();
    [{updated, LastUpdate, _}] when LastUpdate < LastUpdateExpected ->
      refresh();
    [{updated, LastUpdate, _}] when LastUpdate >= LastUpdateExpected ->
      ok
  end,
  {ok, State}.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{table = Table}) ->
  dets:close(Table),
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call({resolve, Hostname} = _Request, _From,
            State = #state{table = Table}) ->
  Result = case dets:lookup(Table, {host, Hostname}) of
    [{{host, Hostname}, Entry}] -> Entry;
    [] -> none
  end,
  {reply, Result, State};

handle_call(list_hosts = _Request, _From, State = #state{table = Table}) ->
  Result = dets:foldl(
    fun
      ({{host, Hostname}, {Hostname, Address, Port, _Creds}}, Acc) ->
        [{Hostname, Address, Port} | Acc];
      (_, Acc) ->
        Acc
    end,
    [],
    Table
  ),
  {reply, Result, State};

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

handle_info({fill, Entries} = _Message, State = #state{table = Table}) ->
  harpcaller_log:info("known hosts registry refreshed",
                      [{entries, length(Entries)}]),
  {MS,S,_US} = os:timestamp(),
  Timestamp = MS * 1000 * 1000 + S,
  % delete all host entries, then re-insert back those that came in this
  % message
  dets:select_delete(Table, ets:fun2ms(fun({{host,_},_}) -> true end)),
  dets:insert(Table, [
    {{host, Hostname}, Entry} ||
    {Hostname, _Addr, _Port, _Creds} = Entry <- Entries
  ]),
  % mark when the last (this) update was performed and some info about it
  dets:insert(Table, {updated, Timestamp, []}),
  {noreply, State};

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

-spec format_address(harpcaller:address()) ->
  string().

format_address(Address) when is_list(Address) ->
  Address;
format_address(Address) when is_atom(Address) ->
  atom_to_list(Address);
format_address({A,B,C,D} = _Address) ->
  % TODO: IPv6
  OctetList = [
    integer_to_list(A),
    integer_to_list(B),
    integer_to_list(C),
    integer_to_list(D)
  ],
  string:join(OctetList, ".").

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
