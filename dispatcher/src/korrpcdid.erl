%%%---------------------------------------------------------------------------
%%% @doc
%%%   Application helper module.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid).

%% public interface
-export([start/0]).
-export([generate_job_id/0]).

-export_type([job_id/0, hostname/0]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-type job_id() :: string().

-type hostname() :: inet:hostname() | inet:ip_address() | binary().

%%% }}}
%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Start KorRPC dispatcher daemon application.

-spec start() ->
  ok | {error, term()}.

start() ->
  start_rec(korrpcdid).

%% @doc Generate a random job ID.

-spec generate_job_id() ->
  job_id().

generate_job_id() ->
  korrpc_uuid:format(korrpc_uuid:uuid()).

%%%---------------------------------------------------------------------------
%%% helpers
%%%---------------------------------------------------------------------------

%% @doc Start an Erlang application, recursively.

-spec start_rec(atom()) ->
  ok | {error, term()}.

start_rec(App) ->
  case application:start(App) of
    ok ->
      ok;
    {error, {already_started, App}} ->
      ok;
    {error, {not_started, App1}} ->
      ok = start_rec(App1),
      start_rec(App);
    {error, Reason} ->
      {error, Reason}
  end.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
