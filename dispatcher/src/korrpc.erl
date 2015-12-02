%%%----------------------------------------------------------------------------
%%% @doc
%%%   KorRPC client module. Connect to KorRPC daemon and call a procedure.
%%% @end
%%%----------------------------------------------------------------------------

-module(korrpc).

-export([call/3]).
-export([request/3, recv/1, recv/2, cancel/1]).

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

-opaque stream_handle() :: ssl:sslsocket().

% }}}
%%%---------------------------------------------------------------------------

%% @doc Call a remote procedure that returns single result.
%%   If the procedure streams its result, this function returns
%%   `{error,streamed}'.
%%
%%   {@type {exception,error_description()@}} is returned if the procedure
%%   raises an exception. Other errors (typically transport-related) are
%%   returned as {@type {error,error_description()|term()@}}.
%%
%%   Available options:
%%
%%   <ul>
%%     <li>{@type {host, inet:hostname() | inet:ip_address()@}} (required)</li>
%%     <li>{@type {port, inet:port_number()@}} (required)</li>
%%     <li>{@type {cafile, file:name()@}}</li>
%%     <li>{@type {timeout, timeout()@}}</li>
%%   </ul>
%%
%% @see request/3

-spec call(procedure(), [argument()], list()) ->
    {ok, result()}
  | {exception, error_description()}
  | {error, streamed | error_description() | term()}.

call(Procedure, Arguments, Options) when is_list(Procedure) ->
  call(list_to_binary(Procedure), Arguments, Options);
call(Procedure, Arguments, Options) when is_atom(Procedure) ->
  call(atom_to_binary(Procedure, unicode), Arguments, Options);
call(Procedure, Arguments, Options) when is_binary(Procedure) ->
  Host = proplists:get_value(host, Options),
  Port = proplists:get_value(port, Options),
  CAFile = proplists:get_value(cafile, Options),
  Timeout = proplists:get_value(timeout, Options, infinity),
  case send_request_1(Procedure, Arguments, Host, Port, CAFile, Timeout) of
    {ok, Conn, single_return} ->
      case ssl_recv(Conn, Timeout) of
        {ok, [{<<"result">>, Result}]} ->
          ssl_close(Conn),
          {ok, Result};
        {ok, [{<<"exception">>, ExceptionDesc}]} ->
          ssl_close(Conn),
          case format_error(ExceptionDesc) of
            {_,_,_} = Exception -> {exception, Exception};
            {_,_}   = Exception -> {exception, Exception};
            _ -> {error, bad_protocol}
          end;
        {ok, _Any} ->
          ssl_close(Conn),
          {error, bad_protocol};
        {error, Reason} ->
          ssl_close(Conn),
          {error, Reason}
      end;
    {ok, Conn, streamed} ->
      ssl_close(Conn),
      {error, streamed};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Call a remote procedure that may return a streamed result.
%%   Stream and the end result are read with {@link recv/1} function.
%%
%%   Call can be aborted with {@link cancel/1}.
%%
%%   {@type {exception,error_description()@}} is returned if the procedure
%%   raises an exception. Other errors (typically transport-related) are
%%   returned as {@type {error,error_description()|term()@}}.
%%
%%   Recognized options are described in {@link call/3}.
%%
%% @see call/3
%% @see recv/1
%% @see cancel/1

-spec request(procedure(), [argument()], list()) ->
  {ok, stream_handle()} | {error, term()}.

request(Procedure, Arguments, Options) when is_list(Procedure) ->
  request(list_to_binary(Procedure), Arguments, Options);
request(Procedure, Arguments, Options) when is_atom(Procedure) ->
  request(atom_to_binary(Procedure, unicode), Arguments, Options);
request(Procedure, Arguments, Options) ->
  Host = proplists:get_value(host, Options),
  Port = proplists:get_value(port, Options),
  CAFile = proplists:get_value(cafile, Options),
  Timeout = proplists:get_value(timeout, Options, infinity),
  case send_request_1(Procedure, Arguments, Host, Port, CAFile, Timeout) of
    {ok, Conn, _ResultType} ->
      {ok, Conn};
    {error, Reason} ->
      {error, Reason}
  end.

%%----------------------------------------------------------
%% sequence of operations to send call request {{{

send_request_1(Procedure, Arguments, Host, Port, CAFile, Timeout) ->
  case ssl_connect(Host, Port, CAFile, Timeout) of
    {ok, Conn}      -> send_request_2(Procedure, Arguments, Conn, Timeout);
    {error, Reason} -> {error, Reason}
  end.

send_request_2(Procedure, Arguments, Conn, Timeout) ->
  Request = [{korrpc, 1}, {procedure, Procedure}, {arguments, Arguments}],
  case ssl_send(Conn, Request) of
    ok ->
      case ssl_recv(Conn, Timeout) of
        {ok, Reply}     -> send_request_3(Conn, Reply);
        {error, Reason} -> {error, Reason}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

send_request_3(Conn, Acknowledgement) ->
  case Acknowledgement of
    [{<<"korrpc">>, 1}, {<<"stream_result">>, true}] ->
      {ok, Conn, streamed};
    [{<<"korrpc">>, 1}, {<<"stream_result">>, false}] ->
      {ok, Conn, single_return};
    %{"korrpc": 1, "error": {"type": "...", "message": "...", "data": ...}}
    [{<<"korrpc">>, 1}, {<<"error">>, ErrorDesc}] ->
      case format_error(ErrorDesc) of
        {_,_,_} = Error -> {error, Error};
        {_,_}   = Error -> {error, Error};
        % TODO: info what was returned
        _Any -> {error, bad_protocol}
      end;
    _Any ->
      % TODO: info what was returned
      ssl_close(Conn),
      {error, bad_protocol}
end.

%% }}}
%%----------------------------------------------------------

%% @equiv recv(Handle, infinity)

-spec recv(stream_handle()) ->
    {packet, korrpc_json:struct()}
  | {result, korrpc_json:struct()}
  | {exception, error_description()}
  | {error, error_description() | term()}.

recv(Handle) ->
  recv(Handle, infinity).

%% @doc Read result (both stream and end result) from a call request created
%%   with {@link request/3}.
%%
%%   Consecutive calls to this function return {@type
%%   {packet,korrpc_json:struct()@}} tuples, which denote streamed result. If
%%   the call returns value of any other form, it marks the end of the stream
%%   and `Handle' is closed.
%%
%%   <ul>
%%     <li>{@type {result,korrpc_json:struct()@}} is returned if the remote
%%       procedure terminated successfully</li>
%%     <li>{@type {exception,error_description()@}} is returned if the remote
%%       procedure raised an exception</li>
%%     <li>{@type {error,term()@}} is returned in the case of a read error
%%       (e.g. connection closed abruptly)</li>
%%   </ul>
%%
%%   If `Timeout' was less than `infinity' and expires, call returns atom
%%   `timeout'.
%%
%% @see request/3
%% @see cancel/1

-spec recv(stream_handle(), timeout()) ->
    timeout
  | {packet, korrpc_json:struct()}
  | {result, korrpc_json:struct()}
  | {exception, error_description()}
  | {error, error_description() | term()}.

recv(Handle, Timeout) ->
  case ssl_recv(Handle, Timeout) of
    {ok, [{<<"stream">>, Packet}]} ->
      {packet, Packet};
    {ok, [{<<"result">>, Result}]} ->
      ssl_close(Handle),
      {result, Result};
    {ok, [{<<"exception">>, ExceptionDesc}]} ->
      ssl_close(Handle),
      case format_error(ExceptionDesc) of
        {_,_,_} = Exception -> {exception, Exception};
        {_,_}   = Exception -> {exception, Exception};
        _ -> {error, bad_protocol}
      end;
    {error, timeout} ->
      timeout;
    {error, Reason} ->
      ssl_close(Handle),
      {error, Reason}
  end.

%% @doc Cancel a call request created with {@link request/3}.
%%
%% @see request/3
%% @see recv/1

-spec cancel(stream_handle()) ->
  ok.

cancel(Handle) ->
  ssl_close(Handle).

%%%---------------------------------------------------------------------------
%%% SSL helpers

%% @doc Connect to specified host/port with SSL/TLS protocol.

-spec ssl_connect(ssl:host(), integer(), file:name() | undefined, timeout()) ->
  {ok, ssl:sslsocket()} | {error, term()}.

ssl_connect(Host, Port, CAFile, Timeout) ->
  case CAFile of
    undefined -> CAOpts = [];
    _ -> CAOpts = [{cacertfile, CAFile}]
  end,
  SocketOpts = [
    {versions, [tlsv1, 'tlsv1.1']}, % TODO: TLS 1.2 and later
    {active, false},
    {packet, line},
    {verify, verify_none}
  ],
  % TODO: verify certificate against CA file
  case ssl:connect(Host, Port, CAOpts ++ SocketOpts, Timeout) of
    {ok, Conn} ->
      {ok, Conn};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Close the SSL socket.

-spec ssl_close(ssl:sslsocket()) ->
  ok.

ssl_close(Conn) ->
  ssl:close(Conn),
  ok.

%% @doc Send data as a JSON line.
%%
%% @see korrpc_json

-spec ssl_send(ssl:sslsocket(), korrpc_json:struct()) ->
  ok | {error, term()}.

ssl_send(Conn, Data) ->
  case korrpc_json:encode(Data) of
    {ok, JSON} ->
      ssl:send(Conn, [JSON, "\n"]);
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Receive and decode response.
%%
%% @see korrpc_json

-spec ssl_recv(ssl:sslsocket(), timeout()) ->
  {ok, korrpc_json:struct()} | {error, term()}.

ssl_recv(Conn, Timeout) ->
  case ssl:recv(Conn, 0, Timeout) of
    {ok, Line} ->
      case korrpc_json:decode(Line) of
        {ok, Data} -> {ok, Data};
        {error, _} -> {error, bad_protocol}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%%%---------------------------------------------------------------------------

%% @doc Format error/exception description from KorRPC protocol.

-spec format_error(term()) ->
  error_description() | bad_format.

format_error([{<<"data">>, Data}, {<<"message">>, Message},
               {<<"type">>, Type}] = _ErrorDesc)
when is_binary(Type), is_binary(Message) ->
  {Type, Message, Data};
format_error([{<<"message">>, Message}, {<<"type">>, Type}] = _ErrorDesc)
when is_binary(Type), is_binary(Message) ->
  {Type, Message};
format_error(_ErrorDesc) ->
  bad_format.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
