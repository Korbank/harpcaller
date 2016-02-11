%%%---------------------------------------------------------------------------
%%% @doc
%%%   Address resolver subsystem supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_hostdb_sup).

-behaviour(supervisor).

%% supervision tree API
-export([start_link/0]).

%% supervisor callbacks
-export([init/1]).

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
  Strategy = {one_for_one, 5, 10},
  Children = [
    {harpcaller_hostdb_refresh, {harpcaller_hostdb_refresh, start_link, []},
      permanent, 1000, worker, [harpcaller_hostdb_refresh]},
    % XXX: harpcaller_hostdb needs harpcaller_hostdb_refresh already running
    {harpcaller_hostdb, {harpcaller_hostdb, start_link, []},
      permanent, 1000, worker, [harpcaller_hostdb]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
