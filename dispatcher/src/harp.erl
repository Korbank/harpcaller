%%%----------------------------------------------------------------------------
%%% @doc
%%%   Harp client module. Connect to Harp daemon and call a procedure.
%%% @end
%%%----------------------------------------------------------------------------

-module(harp).

-export([call/3]).
-export([request/3, recv/1, recv/2, cancel/1, controlling_process/2]).
-export([format_error/1, error_type/1]).

-export_type([procedure/0, argument/0]).
-export_type([stream_record/0, result/0, error_description/0]).
-export_type([handle/0]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-type procedure() :: atom() | string() | binary().

-type argument() :: harp_json:struct().

-type result() :: harp_json:struct().

-type stream_record() :: harp_json:struct().

-type error_description() ::
    {Type :: binary(), Message :: binary()}
  | {Type :: binary(), Message :: binary(), Data :: harp_json:struct()}.

-opaque handle() :: ssl:sslsocket().

-define(CA_VERIFY_DEPTH, 5).

%%% }}}
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
%%     <li>{@type {user, string() | binary()@}} (required)</li>
%%     <li>{@type {password, string() | binary()@}} (required)</li>
%%     <li>{@type {cafile, file:name()@}}</li>
%%     <li>{@type {ssl_verify, @{fun(),term()@}@}} (the same as `{verify_fun,_}'
%%         in {@link ssl:connect/4})</li>
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
  User = iolist_to_binary(proplists:get_value(user, Options)),
  Password = iolist_to_binary(proplists:get_value(password, Options)),
  CAFile = proplists:get_value(cafile, Options),
  CertVerifyFun = proplists:get_value(ssl_verify, Options),
  Timeout = proplists:get_value(timeout, Options, infinity),
  case send_request_1(Procedure, Arguments, Host, Port, User, Password,
                      CAFile, CertVerifyFun, Timeout) of
    {ok, Conn, single_return} ->
      case ssl_recv(Conn, Timeout) of
        {ok, [{<<"result">>, Result}]} ->
          ssl_close(Conn),
          {ok, Result};
        {ok, [{<<"exception">>, ExceptionDesc}]} ->
          ssl_close(Conn),
          case format_protocol_error(ExceptionDesc) of
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
  {ok, handle()} | {error, term()}.

request(Procedure, Arguments, Options) when is_list(Procedure) ->
  request(list_to_binary(Procedure), Arguments, Options);
request(Procedure, Arguments, Options) when is_atom(Procedure) ->
  request(atom_to_binary(Procedure, unicode), Arguments, Options);
request(Procedure, Arguments, Options) ->
  Host = proplists:get_value(host, Options),
  Port = proplists:get_value(port, Options),
  User = iolist_to_binary(proplists:get_value(user, Options)),
  Password = iolist_to_binary(proplists:get_value(password, Options)),
  CAFile = proplists:get_value(cafile, Options),
  CertVerifyFun = proplists:get_value(ssl_verify, Options),
  Timeout = proplists:get_value(timeout, Options, infinity),
  case send_request_1(Procedure, Arguments, Host, Port, User, Password,
                      CAFile, CertVerifyFun, Timeout) of
    {ok, Conn, _ResultType} ->
      {ok, Conn};
    {error, Reason} ->
      {error, Reason}
  end.

%%----------------------------------------------------------
%% sequence of operations to send call request {{{

send_request_1(Procedure, Arguments, Host, Port, User, Password,
               CAFile, CertVerifyFun, Timeout) ->
  case ssl_connect(Host, Port, CAFile, CertVerifyFun, Timeout) of
    {ok, Conn} ->
      send_request_2(Procedure, Arguments, User, Password, Conn, Timeout);
    {error, Reason} ->
      {error, Reason}
  end.

send_request_2(Procedure, Arguments, User, Password, Conn, Timeout) ->
  Request = [
    {harp, 1},
    {procedure, Procedure}, {arguments, Arguments},
    {auth, [{user, User}, {password, Password}]}
  ],
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
    [{<<"harp">>, 1}, {<<"stream_result">>, true}] ->
      {ok, Conn, streamed};
    [{<<"harp">>, 1}, {<<"stream_result">>, false}] ->
      {ok, Conn, single_return};
    %{"harp": 1, "error": {"type": "...", "message": "...", "data": ...}}
    [{<<"error">>, ErrorDesc}, {<<"harp">>, 1}] ->
      case format_protocol_error(ErrorDesc) of
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

-spec recv(handle()) ->
    {packet, harp_json:struct()}
  | {result, harp_json:struct()}
  | {exception, error_description()}
  | {error, error_description() | term()}.

recv(Handle) ->
  recv(Handle, infinity).

%% @doc Read result (both stream and end result) from a call request created
%%   with {@link request/3}.
%%
%%   Consecutive calls to this function return {@type
%%   {packet,stream_record()@}} tuples, which denote streamed result.
%%   If the call returns value of any other form, it marks the end of the
%%   stream and `Handle' is closed.
%%
%%   <ul>
%%     <li>{@type {result,result()@}} is returned if the remote procedure
%%       terminated successfully</li>
%%     <li>{@type {exception,error_description()@}} is returned if the remote
%%       procedure raised an exception</li>
%%     <li>{@type {error,error_description()|term()@}} is returned in the case
%%       of a read error (e.g. connection closed abruptly)</li>
%%   </ul>
%%
%%   If `Timeout' was less than `infinity' and expires, call returns atom
%%   `timeout'.
%%
%% @see request/3
%% @see cancel/1

-spec recv(handle(), timeout()) ->
    timeout
  | {packet, harp_json:struct()}
  | {result, harp_json:struct()}
  | {exception, error_description()}
  | {error, error_description() | term()}.

recv(Handle, Timeout) ->
  case ssl_recv(Handle, Timeout) of
    {ok, [{<<"stream">>, Packet}]} ->
      {packet, Packet};
    {ok, [{<<"result">>, Result}]} ->
      ssl_close(Handle),
      {result, Result};
    {ok, [{<<"error">>, ErrorDescription}, {<<"harp">>, 1}]} ->
      ssl_close(Handle),
      case format_protocol_error(ErrorDescription) of
        {_,_,_} = Error -> {error, Error};
        {_,_}   = Error -> {error, Error};
        _ -> {error, bad_protocol}
      end;
    {ok, [{<<"exception">>, ExceptionDesc}]} ->
      ssl_close(Handle),
      case format_protocol_error(ExceptionDesc) of
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

-spec cancel(handle()) ->
  ok.

cancel(Handle) ->
  ssl_close(Handle).

%% @doc Assign a new controlling process to call request.

-spec controlling_process(handle(), pid()) ->
  ok | {error, term()}.

controlling_process(Handle, Pid) ->
  ssl:controlling_process(Handle, Pid).

%%%---------------------------------------------------------------------------
%%% SSL helpers

%% @doc Connect to specified host/port with SSL/TLS protocol.

-spec ssl_connect(ssl:host(), integer(), file:name() | undefined,
                  {fun(), term()}, timeout()) ->
  {ok, ssl:sslsocket()} | {error, term()}.

ssl_connect(_Host, Port, _CAFile, _CertVerifyFun, _Timeout)
when not is_integer(Port); Port =< 0; Port >= 65536 ->
  % if we left validating port number to `ssl:connect()' in the actual call,
  % invalid port would result in a completely unreadable error
  {error, bad_address};
ssl_connect(Host, Port, CAFile, CertVerifyFun, Timeout) ->
  case {CAFile, CertVerifyFun} of
    {undefined, undefined} ->
      CertOpts = [{verify, verify_none}];
    {undefined, {_Fun,_Arg}} ->
      CertOpts = [
        {verify, verify_peer},
        {verify_fun, CertVerifyFun}
      ];
    {_Path, undefined} ->
      CertOpts = [
        {verify, verify_peer},
        {depth, ?CA_VERIFY_DEPTH},
        {cacertfile, CAFile}
      ];
    {_Path, {_Fun,_Arg}} ->
      CertOpts = [
        {verify, verify_peer},
        {depth, ?CA_VERIFY_DEPTH},
        {cacertfile, CAFile},
        {verify_fun, CertVerifyFun}
      ]
  end,
  SocketOpts = [
    {versions, [tlsv1, 'tlsv1.1']}, % TODO: TLS 1.2 and later
    {active, false},
    {packet, line}
  ],
  % if we left host resolution to `ssl:connect()', incorrectly formatted
  % hostname/IP address would result in a completely unreadable error
  case resolve(Host) of
    {ok, Addr} ->
      case ssl:connect(Addr, Port, CertOpts ++ SocketOpts, Timeout) of
        {ok, Conn} ->
          {ok, Conn};
        {error, closed = Reason} ->
          {error, Reason};
        {error, timeout = Reason} ->
          {error, Reason};
        {error, Reason} when is_atom(Reason) ->
          case inet:format_error(Reason) of
            "unknown POSIX" ++ _ -> {error, {ssl, Reason}};
            _ -> {error, Reason}
          end;
        {error, Reason} ->
          {error, {ssl, Reason}}
      end;
    {error, einval} ->
      {error, bad_address};
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Resolve host address.

-spec resolve(inet:hostname()) ->
  {ok, inet:ip_address()} | {error, term()}.

resolve(Host) ->
  case inet:getaddr(Host, inet) of
    {ok, Addr} -> {ok, Addr};
    {error, nxdomain} -> inet:getaddr(Host, inet6);
    {error, eafnosupport} -> inet:getaddr(Host, inet6);
    {error, Reason} -> {error, Reason}
  end.

%% @doc Close the SSL socket.

-spec ssl_close(ssl:sslsocket()) ->
  ok.

ssl_close(Conn) ->
  ssl:close(Conn),
  ok.

%% @doc Send data as a JSON line.
%%
%% @see harp_json

-spec ssl_send(ssl:sslsocket(), harp_json:struct()) ->
  ok | {error, term()}.

ssl_send(Conn, Data) ->
  case harp_json:encode(Data) of
    {ok, JSON} ->
      ssl:send(Conn, [JSON, "\n"]);
    {error, Reason} ->
      {error, Reason}
  end.

%% @doc Receive and decode response.
%%
%% @see harp_json

-spec ssl_recv(ssl:sslsocket(), timeout()) ->
  {ok, harp_json:struct()} | {error, term()}.

ssl_recv(Conn, Timeout) ->
  case ssl:recv(Conn, 0, Timeout) of
    {ok, Line} ->
      case harp_json:decode(Line) of
        {ok, Data} -> {ok, Data};
        {error, _} -> {error, bad_protocol}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%%%---------------------------------------------------------------------------

%% @doc Format error/exception description from HarpRPC protocol.

-spec format_protocol_error(term()) ->
  error_description() | bad_format.

format_protocol_error([{<<"data">>, Data}, {<<"message">>, Message},
                       {<<"type">>, Type}] = _ErrorDesc)
when is_binary(Type), is_binary(Message) ->
  {Type, Message, Data};
format_protocol_error([{<<"message">>, Message},
                       {<<"type">>, Type}] = _ErrorDesc)
when is_binary(Type), is_binary(Message) ->
  {Type, Message};
format_protocol_error(_ErrorDesc) ->
  bad_format.

%%%---------------------------------------------------------------------------

%% @doc Convert an error to a printable form.

-spec format_error(term()) ->
  iolist().

format_error(bad_address = _Error) ->
  "invalid host address or port number";
format_error(bad_protocol = _Error) ->
  "Harp protocol error";
format_error(bad_format = _Error) ->
  % error was signaled by the remote harpd in wrong way
  "Harp protocol error";
format_error(badarg = _Error) ->
  % data to send (e.g. arguments or procedure name) can't be encoded to JSON
  "bad argument"; % TODO: be more descriptive
format_error({ssl, Reason} = _Error) ->
  ssl:format_error(Reason);
format_error(timeout = _Error) ->
  "request timed out";
format_error(closed = _Error) ->
  "connection closed unexpectedly";
format_error(Error) when is_atom(Error) ->
  inet:format_error(Error);
format_error(Error) ->
  io_lib:format("unknown error: ~1024p", [Error]).

%% @doc Determine error category.

-spec error_type(term()) ->
  string().

error_type({ssl, _} = _Error) -> "ssl";
error_type(timeout = _Error) -> "timeout";
error_type(closed = _Error) -> "closed";
error_type(Error) when is_atom(Error) -> atom_to_list(Error); % inet:posix()
error_type(_Error) -> "unrecognized".

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
