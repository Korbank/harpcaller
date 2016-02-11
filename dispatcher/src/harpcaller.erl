%%%---------------------------------------------------------------------------
%%% @doc
%%%   Application helper module.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller).

%% public interface
-export([start/0]).
-export([generate_job_id/0, valid_job_id/1]).

-export_type([job_id/0, hostname/0, address/0]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-type job_id() :: string().

-type hostname() :: binary().

-type address() :: inet:hostname() | inet:ip_address().

%%% }}}
%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Start HarpCaller daemon application.

-spec start() ->
  ok | {error, term()}.

start() ->
  start_rec(harpcaller).

%% @doc Generate a random job ID.

-spec generate_job_id() ->
  job_id().

generate_job_id() ->
  harp_uuid:format(harp_uuid:uuid()).

%% @doc Check job ID for being valid.

-spec valid_job_id(string() | binary()) ->
  boolean().

valid_job_id(JobID) when is_binary(JobID) ->
  valid_job_id(binary_to_list(JobID));
valid_job_id(JobID) when is_list(JobID) ->
  case harp_uuid:version(JobID) of
    Version when is_integer(Version) -> true;
    false -> false
  end.

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
