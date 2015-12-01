%%%----------------------------------------------------------------------------
%%% @doc
%%%   KorRPC client module. Connect to KorRPC daemon and call a procedure.
%%% @end
%%%----------------------------------------------------------------------------

-module(korrpc).

-export([call/3]).
-export([request/3, recv/1, cancel/1]).

-export_type([procedure/0, argument/0, result/0, error_description/0]).
-export_type([stream_handle/0]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-type procedure() :: atom() | string() | binary().

-type argument() :: korrpc_json:struct().

-type result() :: korrpc_json:struct().

-type error_description() ::
    {Type :: binary(), Message :: binary()}
  | {Type :: binary(), Message :: binary(), Data :: korrpc_json:struct()}.

-opaque stream_handle() :: port().

% }}}
%%%---------------------------------------------------------------------------

%% @doc Call a remote procedure that returns single result.
%%   If the procedure streams its result, this function returns
%%   `{error,streamed}'.
%%
%%   `{exception,_}' is returned if the procedure raises an exception. Other
%%   errors (typically transport-related) are returned as `{error,_}'.
%%
%% @see request/3

-spec call(procedure(), [argument()], list()) ->
    {ok, result()}
  | {exception, error_description()}
  | {error, streamed | error_description() | term()}.

call(_Procedure, _Arguments, _Options) ->
  'TODO'.

%% @doc Call a remote procedure that may return a streamed result.
%%   Stream and the end result are read with {@link recv/1} function.
%%
%%   Call can be aborted with {@link cancel/1}.
%%
%%   `{exception,_}' is returned if the procedure raises an exception. Other
%%   errors (typically transport-related) are returned as `{error,_}'.
%%
%% @see recv/1
%% @see cancel/1

-spec request(procedure(), [argument()], list()) ->
  {ok, stream_handle()} | {error, term()}.

request(_Procedure, _Arguments, _Options) ->
  'TODO'.

%% @doc Read result (both stream and end result) from a call request created
%%   with {@link request/3}.
%%
%%   Consecutive calls to this function return `{packet,_}' tuples, which
%%   denote streamed result. If the call returns value of any other form, it
%%   marks the end of the stream and `Handle' is closed.
%%
%%   <ul>
%%     <li>`{result,_}' is returned if the remote procedure terminated
%%       successfully</li>
%%     <li>`{exception,_}' is returned if the remote procedure raised an
%%       exception</li>
%%     <li>`{error,_}' is returned in the case of a read error (e.g.
%%       connection closed abruptly)</li>
%%   </ul>
%%
%% @see request/3
%% @see cancel/1

-spec recv(stream_handle()) ->
    {packet, korrpc_json:struct()}
  | {result, korrpc_json:struct()}
  | {exception, error_description()}
  | {error, error_description() | term()}.

recv(_Handle) ->
  'TODO'.

%% @doc Cancel a call request created with {@link request/3}.
%%
%% @see request/3
%% @see recv/1

-spec cancel(stream_handle()) ->
  ok.

cancel(_Handle) ->
  'TODO'.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
