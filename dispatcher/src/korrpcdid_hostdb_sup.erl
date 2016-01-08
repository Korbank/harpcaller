%%%---------------------------------------------------------------------------
%%% @doc
%%%   Address resolver subsystem supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_hostdb_sup).

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
    {korrpcdid_hostdb_refresh, {korrpcdid_hostdb_refresh, start_link, []},
      permanent, 1000, worker, [korrpcdid_hostdb_refresh]},
    % XXX: korrpcdid_hostdb needs korrpcdid_hostdb_refresh already running
    {korrpcdid_hostdb, {korrpcdid_hostdb, start_link, []},
      permanent, 1000, worker, [korrpcdid_hostdb]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
