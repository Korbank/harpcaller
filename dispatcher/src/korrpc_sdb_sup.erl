%%%---------------------------------------------------------------------------
%%% @private
%%% @doc
%%%   Supervisor for {@link korrpc_sdb} processes.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpc_sdb_sup).

-behaviour(supervisor).

%% public interface
-export([spawn_child/1]).

%% supervision tree API
-export([start_link/0]).

%% supervisor callbacks
-export([init/1]).

%%%---------------------------------------------------------------------------

-include("korrpc_sdb.hrl").

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

-spec spawn_child(term()) ->
  {ok, pid()} | {ok, undefined} | {error, term()}.

spawn_child(Args) ->
  supervisor:start_child(?MODULE, Args).

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start the supervisor process.

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%%---------------------------------------------------------------------------
%%% supervisor callbacks
%%%---------------------------------------------------------------------------

%% @private
%% @doc Initialize supervisor.

init([] = _Args) ->
  Strategy = {simple_one_for_one, 5, 10},
  Children = [
    {undefined, {korrpc_sdb, start_link, []},
      temporary, 1000, worker, [korrpc_sdb]}
  ],
  ?ETS_REGISTRY_TABLE = ets:new(?ETS_REGISTRY_TABLE, [
    named_table, public, set,
    {write_concurrency, true}, {read_concurrency, true}
  ]),
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
