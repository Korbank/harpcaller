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
%%% public interface
%%%---------------------------------------------------------------------------

-spec spawn_child(term()) ->
  {ok, pid()} | {error, term()}.

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
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
