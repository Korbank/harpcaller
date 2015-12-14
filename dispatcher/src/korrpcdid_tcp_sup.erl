%%%---------------------------------------------------------------------------
%%% @doc
%%%   TCP subsystem supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_tcp_sup).

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
  {ok, ListenAddrs} = application:get_env(listen),
  Listeners = [
    {{korrpcdid_tcp_listener, Addr},
      {korrpcdid_tcp_listener, start_link, [Addr]},
      permanent, 1000, worker, [korrpcdid_tcp_listener]} ||
    Addr <- ListenAddrs
  ],
  Children = [
    {korrpcdid_tcp_worker_sup, {korrpcdid_tcp_worker_sup, start_link, []},
      permanent, 1000, supervisor, [korrpcdid_tcp_worker_sup]}
  ],
  {ok, {Strategy, Children ++ Listeners}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
