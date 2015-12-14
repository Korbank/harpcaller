%%%---------------------------------------------------------------------------
%%% @doc
%%%   KorRPC dispatcher top-level supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_sup).

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
    {korrpc_sdb_sup, {korrpc_sdb_sup, start_link, []},
      permanent, 1000, worker, [korrpc_sdb_sup]},
    {korrpcdid_caller_sup, {korrpcdid_caller_sup, start_link, []},
      permanent, 1000, supervisor, [korrpcdid_caller_sup]},
    {korrpcdid_tcp_sup, {korrpcdid_tcp_sup, start_link, []},
      permanent, 1000, supervisor, [korrpcdid_tcp_sup]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
