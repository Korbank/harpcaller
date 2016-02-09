%%%---------------------------------------------------------------------------
%%% @doc
%%%   KorRPC call subsystem supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_call_sup).

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
  Strategy = {rest_for_one, 5, 10},
  Children = [
    {korrpcdid_call_queue, {korrpcdid_call_queue, start_link, []},
      permanent, 1000, worker, [korrpcdid_call_queue]},
    {korrpcdid_x509_store, {korrpcdid_x509_store, start_link, []},
      permanent, 1000, worker, [korrpcdid_x509_store]},
    {korrpcdid_caller_sup, {korrpcdid_caller_sup, start_link, []},
      permanent, 1000, supervisor, [korrpcdid_caller_sup]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
