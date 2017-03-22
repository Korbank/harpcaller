%%%---------------------------------------------------------------------------
%%% @doc
%%%   HarpCaller top-level supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_sup).

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
  {ok, LogHandlers} = application:get_env(log_handlers),
  Strategy = {one_for_one, 5, 10},
  Children = [
    {harpcaller_log, {harpcaller_log, start_link, [LogHandlers]},
      permanent, 1000, worker, dynamic},
    {harp_sdb_sup, {harp_sdb_sup, start_link, []},
      permanent, 1000, supervisor, [harp_sdb_sup]},
    {harp_sdb_cleanup, {harp_sdb_cleanup, start_link, []},
      permanent, 1000, worker, [harp_sdb_cleanup]},
    {harpcaller_call_sup, {harpcaller_call_sup, start_link, []},
      permanent, 1000, supervisor, [harpcaller_call_sup]},
    {harpcaller_hostdb_sup, {harpcaller_hostdb_sup, start_link, []},
      permanent, 1000, supervisor, [harpcaller_hostdb_sup]},
    {harpcaller_tcp_sup, {harpcaller_tcp_sup, start_link, []},
      permanent, 1000, supervisor, [harpcaller_tcp_sup]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
