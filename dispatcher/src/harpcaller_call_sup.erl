%%%---------------------------------------------------------------------------
%%% @doc
%%%   HarpRPC call subsystem supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_call_sup).

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
    {harpcaller_call_queue, {harpcaller_call_queue, start_link, []},
      permanent, 1000, worker, [harpcaller_call_queue]},
    {harpcaller_x509_store, {harpcaller_x509_store, start_link, []},
      permanent, 1000, worker, [harpcaller_x509_store]},
    {harpcaller_caller_sup, {harpcaller_caller_sup, start_link, []},
      permanent, 1000, supervisor, [harpcaller_caller_sup]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
