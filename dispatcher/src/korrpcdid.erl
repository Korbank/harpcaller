%%%---------------------------------------------------------------------------
%%% @doc
%%%   Application helper module.
%%% @end
%%%---------------------------------------------------------------------------

-module(korrpcdid).

%% public interface
-export([start/0]).

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Start KorRPC dispatcher daemon application.

-spec start() ->
  ok | {error, term()}.

start() ->
  start_rec(korrpcdid).

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
