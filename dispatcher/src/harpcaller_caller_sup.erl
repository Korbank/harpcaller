%%%---------------------------------------------------------------------------
%%% @doc
%%%   Harp daemon calling subsystem supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_caller_sup).

-behaviour(supervisor).

%% public interface
-export([spawn_caller/4]).

%% supervision tree API
-export([start_link/0]).

%% supervisor callbacks
-export([init/1]).

%%%---------------------------------------------------------------------------

-include("harpcaller_caller.hrl").

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Spawn a new worker process.
%%   `Options' are passed to {@link harpcaller_caller} (back) without change.

-spec spawn_caller(harp:procedure(), [harp:argument()],
                   harpcaller:hostname(), [term()]) ->
  {ok, pid(), harpcaller:job_id()} | {error, term()}.

spawn_caller(Procedure, ProcArgs, Host, Options) ->
  supervisor:start_child(?MODULE, [Procedure, ProcArgs, Host, Options]).

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
    {undefined, {harpcaller_caller, start_link, []},
      temporary, 1000, worker, [harpcaller_caller]}
  ],
  ?ETS_REGISTRY_TABLE = ets:new(?ETS_REGISTRY_TABLE, [
    named_table, public, set,
    {write_concurrency, true}, {read_concurrency, true}
  ]),
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
