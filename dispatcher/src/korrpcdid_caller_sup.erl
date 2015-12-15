%%%---------------------------------------------------------------------------
%%% @doc
%%%   KorRPC daemon calling subsystem supervisor.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid_caller_sup).

-behaviour(supervisor).

%% public interface
-export([spawn_caller/4]).

%% supervision tree API
-export([start_link/0]).

%% supervisor callbacks
-export([init/1]).

%%%---------------------------------------------------------------------------

-include("korrpcdid_caller.hrl").

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Spawn a new worker process.

-spec spawn_caller(korrpc:procedure(), [korrpc:argument()],
                   inet:hostname() | inet:ip_address(), inet:port_number()) ->
  {ok, pid(), korrpcdid:job_id()} | {error, term()}.

spawn_caller(Procedure, ProcArgs, Host, Port) ->
  supervisor:start_child(?MODULE, [Procedure, ProcArgs, Host, Port]).

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
    {undefined, {korrpcdid_caller, start_link, []},
      temporary, 1000, worker, [korrpcdid_caller]}
  ],
  ?ETS_REGISTRY_TABLE = ets:new(?ETS_REGISTRY_TABLE, [
    named_table, public, set,
    {write_concurrency, true}, {read_concurrency, true}
  ]),
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
