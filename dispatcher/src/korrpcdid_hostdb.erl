%%%---------------------------------------------------------------------------
%%% @doc
%%%   Address resolver for known hosts.
%%%   The process also stores credentials and port numbers of the hosts.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_hostdb).

-behaviour(gen_server).

%% public interface
-export([resolve/1, refresh/0]).

%% supervision tree API
-export([start/0, start_link/0]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

-export_type([host_entry/0]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-record(state, {}).

-type host_entry() :: {
  Name :: korrpcdid:hostname(),
  Port :: inet:port_number(),
  Address :: korrpcdid:address(),
  Credentials :: term()
}.

%%% }}}
%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Retrieve address, port, and credentials necessary to connect to
%%   specified host.

-spec resolve(korrpcdid:hostname()) ->
  korrpcdid_hostdb:host_entry() | none.

resolve(_Hostname) ->
  'TODO'.

%% @doc Force refreshing list of hosts out of regular schedule.

-spec refresh() ->
  ok.

refresh() ->
  korrpcdid_hostdb_refresh:refresh().

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start example process.

start() ->
  gen_server:start(?MODULE, [], []).

%% @private
%% @doc Start example process.

start_link() ->
  gen_server:start_link(?MODULE, [], []).

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init(_Args) ->
  State = #state{},
  {ok, State}.

%% @private
%% @doc Clean up after event handler.

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

%% unknown casts
handle_cast(_Request, State) ->
  {noreply, State}.

%% @private
%% @doc Handle incoming messages.

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
